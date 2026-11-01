package com.ztransfer.protocol

import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.hardware.usb.UsbManager
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import com.ztransfer.viewmodel.StaCameraProfileStore
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking

/** Real STA sockets/handshake against a loopback camera, with isolated pairing preferences. */
class StaPairingHandshakeInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val report = Bundle()
        val passed = mutableListOf<String>()
        try {
            check(Build.FINGERPRINT.contains("generic") || Build.MODEL.contains("sdk", true)) {
                "The synthetic STA pairing server is emulator-only"
            }
            check((targetContext.getSystemService(Context.USB_SERVICE) as UsbManager).deviceList.isEmpty())
            runBlocking {
                for (event in listOf(
                    PairingEvent.EOF,
                    PairingEvent.UNRELATED_THEN_EOF,
                    PairingEvent.SHORT_CHANGED_THEN_EOF,
                    PairingEvent.STALE_CHANGED_THEN_EOF,
                    PairingEvent.TIMEOUT_CONNECTED,
                )) {
                    withFixture { fixture ->
                        FakeStaServer(listOf(SessionPlan(event = event))).use { server ->
                            val camera = NikonCamera(fixture)
                            try {
                                val startedAt = System.nanoTime()
                                val result = camera.connectSta(
                                    ip = LOOPBACK,
                                    forceProfilePairing = true,
                                    exploreAlbumAccess = true,
                                )
                                check(result.exceptionOrNull() is StaPairingConfirmationMissingException) {
                                    "$event must not produce a pairing receipt: ${result.exceptionOrNull()}\n" +
                                        camera.staDiagnosticReport
                                }
                                check(!camera.staPairingConfirmed && !camera.staAlbumAccessValidated)
                                if (event == PairingEvent.TIMEOUT_CONNECTED) {
                                    check(TimeUnit.NANOSECONDS.toSeconds(System.nanoTime() - startedAt) >= 25) {
                                        "The no-event test failed before the production confirmation timeout"
                                    }
                                }
                                fixture.assertNoPairingMarker(GUID_A)
                                check(server.commandCodes().count { it == PtpConstants.NK_PAIRING_QUERY } == 1)
                                check(server.commandCodes().count { it == PtpConstants.NK_PAIRING_RESULT } == 1)
                            } finally { camera.close() }
                            server.awaitFinished()
                        }
                    }
                    passed += "unconfirmed $event cannot activate or persist"
                }

                withFixture { fixture ->
                    FakeStaServer(listOf(
                        SessionPlan(event = PairingEvent.FRESH_CHANGED),
                        SessionPlan(),
                    )).use { server ->
                        val first = NikonCamera(fixture)
                        val receipt = try {
                            val result = first.connectSta(
                                ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                            )
                            val completion = result.exceptionOrNull() as? PairingCompletedException
                                ?: error("Fresh event did not yield a receipt: ${result.exceptionOrNull()}\n" +
                                    first.staDiagnosticReport)
                            check(completion.confirmation.responderGuid == GUID_A)
                            check(!first.staPairingConfirmed && !first.staAlbumAccessValidated)
                            fixture.assertNoPairingMarker(GUID_A)
                            completion.confirmation
                        } finally { first.close() }
                        val reconnect = NikonCamera(fixture)
                        try {
                            reconnect.connectSta(
                                ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                                pairingConfirmation = receipt,
                            ).getOrThrow()
                            check(reconnect.staPairingConfirmed && reconnect.staAlbumAccessValidated)
                            check(fixture.pairingPrefs().getBoolean(STA_PAIRING_VERIFIED_MARKER_PREFIX + GUID_A, false))
                            check(server.commandCodes().count { it == PtpConstants.NK_PAIRING_QUERY } == 1)
                            check(server.commandCodes().count { it == PtpConstants.NK_PAIRING_RESULT } == 1)
                            check(server.commandCodes().contains(Lab.NK_GET_LIVE_VIEW_IMG))
                            check(server.commandCodes().count { it == Lab.NK_END_LIVE_VIEW } == 1)
                        } finally { reconnect.close() }
                        server.awaitFinished()
                        check(server.initiators().distinct().size == 1) { "Reconnect changed the paired host identity" }
                    }
                }
                passed += "fresh confirmation plus same-camera valid frame persists pairing"

                for (liveView in listOf(
                    LiveViewCase.START_EOF, LiveViewCase.FRAME_EOF, LiveViewCase.START_DENIED,
                    LiveViewCase.BAD_FRAME, LiveViewCase.END_DENIED,
                )) {
                    withFixture { fixture ->
                        FakeStaServer(listOf(
                            SessionPlan(event = PairingEvent.FRESH_CHANGED),
                            SessionPlan(liveView = liveView),
                        )).use { server ->
                            val receipt = obtainConfirmation(fixture)
                            val camera = NikonCamera(fixture)
                            try {
                                val result = camera.connectSta(
                                    ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                                    pairingConfirmation = receipt,
                                )
                                check(result.exceptionOrNull() is PairingNotConfirmedException) {
                                    "$liveView must reject pairing: ${result.exceptionOrNull()}\n${camera.staDiagnosticReport}"
                                }
                                check(!camera.staPairingConfirmed)
                                fixture.assertNoPairingMarker(GUID_A)
                                val ends = server.commandCodes().count { it == Lab.NK_END_LIVE_VIEW }
                                check(ends == if (liveView in listOf(LiveViewCase.BAD_FRAME, LiveViewCase.END_DENIED)) 1 else 0) {
                                    "$liveView sent $ends EndLiveView commands"
                                }
                            } finally { camera.close() }
                            server.awaitFinished()
                        }
                    }
                    passed += "$liveView cannot persist pairing and respects LV cleanup ownership"
                }

                for (liveView in listOf(LiveViewCase.ALREADY_ACTIVE, LiveViewCase.BUSY_THEN_READY)) {
                    withFixture { fixture ->
                        FakeStaServer(listOf(
                            SessionPlan(event = PairingEvent.FRESH_CHANGED),
                            SessionPlan(liveView = liveView),
                        )).use { server ->
                            val receipt = obtainConfirmation(fixture)
                            val camera = NikonCamera(fixture)
                            try {
                                camera.connectSta(
                                    ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                                    pairingConfirmation = receipt,
                                ).getOrThrow()
                                check(camera.staPairingConfirmed && camera.staAlbumAccessValidated)
                                check(fixture.pairingPrefs().getBoolean(STA_PAIRING_VERIFIED_MARKER_PREFIX + GUID_A, false))
                                val codes = server.commandCodes()
                                check(Lab.NK_GET_LIVE_VIEW_IMG in codes)
                                if (liveView == LiveViewCase.ALREADY_ACTIVE) {
                                    check(codes.none { it == Lab.NK_START_LIVE_VIEW || it == Lab.NK_END_LIVE_VIEW })
                                } else {
                                    check(codes.count { it == Lab.NK_DEVICE_READY } >= 2)
                                    check(codes.count { it == Lab.NK_GET_LIVE_VIEW_IMG } >= 2)
                                    check(codes.count { it == Lab.NK_END_LIVE_VIEW } == 1)
                                }
                            } finally { camera.close() }
                            server.awaitFinished()
                        }
                    }
                    passed += "$liveView verifies a frame without disrupting an existing monitor"
                }

                for (cancelDuringFrame in listOf(false, true)) {
                    withFixture { fixture ->
                        FakeStaServer(listOf(
                            SessionPlan(event = PairingEvent.FRESH_CHANGED),
                            SessionPlan(liveView = LiveViewCase.GATED_FRAME),
                        )).use { server ->
                            val receipt = obtainConfirmation(fixture)
                            val camera = NikonCamera(fixture)
                            try {
                                coroutineScope {
                                    val connection = async(Dispatchers.Default) {
                                        camera.connectSta(
                                            ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                                            pairingConfirmation = receipt,
                                        )
                                    }
                                    server.awaitFrameRequest()
                                    check(!camera.staPairingConfirmed)
                                    fixture.assertNoPairingMarker(GUID_A)
                                    if (cancelDuringFrame) connection.cancel()
                                    server.releaseFrame()
                                    if (cancelDuringFrame) {
                                        var cancelled = false
                                        try { connection.await() } catch (_: CancellationException) { cancelled = true }
                                        check(cancelled) { "Cancellation accepted a late valid frame" }
                                        check(!camera.staPairingConfirmed)
                                        fixture.assertNoPairingMarker(GUID_A)
                                    } else {
                                        connection.await().getOrThrow()
                                        check(camera.staPairingConfirmed)
                                        check(fixture.pairingPrefs().getBoolean(STA_PAIRING_VERIFIED_MARKER_PREFIX + GUID_A, false))
                                    }
                                    check(server.commandCodes().count { it == Lab.NK_END_LIVE_VIEW } == 1) {
                                        "A complete frame response must allow cleanup of the monitor we started"
                                    }
                                }
                            } finally {
                                server.releaseFrame()
                                camera.close()
                            }
                            server.awaitFinished()
                        }
                    }
                    passed += if (cancelDuringFrame) "cancelled frame reception cleans own LV without persisting pairing"
                        else "Start and DeviceReady alone cannot persist pairing before a valid frame"
                }

                withFixture { fixture ->
                    fixture.pairingPrefs().edit().putString("initiator_id", SAVED_INITIATOR).commit()
                    FakeStaServer(listOf(
                        SessionPlan(event = PairingEvent.FRESH_CHANGED),
                        SessionPlan(),
                    )).use { server ->
                        val receipt = obtainConfirmation(fixture)
                        val camera = NikonCamera(fixture)
                        try {
                            coroutineScope {
                                val connection = synchronized(staPairingStateLock) {
                                    val pending = async(Dispatchers.Default) {
                                        camera.connectSta(
                                            ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                                            pairingConfirmation = receipt,
                                        )
                                    }
                                    try {
                                        server.awaitLiveViewEnd()
                                        // Wait for the real commit boundary, not an arbitrary delay:
                                        // cancelling during frame IO is already covered above.
                                        awaitBlockedPairingCommit()
                                        pending.cancel()
                                        StaCameraProfileStore(
                                            fixture.getSharedPreferences("route_fixture", Context.MODE_PRIVATE),
                                            fixture.pairingPrefs(),
                                        ).resetPairing()
                                        fixture.assertNoPairingMarker(GUID_A)
                                        check(!fixture.pairingPrefs().contains("initiator_id"))
                                        pending
                                    } catch (error: Throwable) {
                                        pending.cancel()
                                        throw error
                                    }
                                }
                                var cancelled = false
                                try { connection.await() } catch (_: CancellationException) { cancelled = true }
                                check(cancelled) { "A cancelled commit survived pairing reset" }
                                check(!camera.staPairingConfirmed)
                                fixture.assertNoPairingMarker(GUID_A)
                                check(!fixture.pairingPrefs().contains("initiator_id")) {
                                    "A pending connection revived the cleared host identity"
                                }
                                check(server.commandCodes().count { it == Lab.NK_END_LIVE_VIEW } == 1)
                            }
                        } finally { camera.close() }
                        server.awaitFinished()
                    }
                }
                passed += "reset while final pairing commit waits cannot revive cancelled trust or identity"

                for (staleTrusted in listOf(false, true)) {
                    withFixture { fixture ->
                        if (staleTrusted) {
                            fixture.pairingPrefs().edit()
                                .putString("initiator_id", SAVED_INITIATOR)
                                .putBoolean(STA_PAIRING_MARKER_PREFIX + GUID_A, true)
                                .putBoolean(STA_PAIRING_VERIFIED_MARKER_PREFIX + GUID_A, true)
                                .commit()
                        }
                        FakeStaServer(listOf(
                            SessionPlan(event = PairingEvent.FRESH_CHANGED, pairingOnlyDeviceInfo = staleTrusted),
                            SessionPlan(liveView = LiveViewCase.START_DENIED),
                            SessionPlan(event = PairingEvent.FRESH_CHANGED),
                            SessionPlan(),
                        )).use { server ->
                            val firstReceipt = obtainConfirmation(fixture)
                            fixture.assertNoPairingMarker(GUID_A)
                            if (staleTrusted) {
                                check(fixture.pairingPrefs().getString("initiator_id", null) == SAVED_INITIATOR)
                            }
                            val firstAttempt = NikonCamera(fixture)
                            try {
                                val result = firstAttempt.connectSta(
                                    ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                                    pairingConfirmation = firstReceipt,
                                )
                                check(result.exceptionOrNull() is PairingNotConfirmedException)
                                check(!firstAttempt.staPairingConfirmed)
                                fixture.assertNoPairingMarker(GUID_A)
                            } finally { firstAttempt.close() }
                            // Exercise the one full-handshake repair sequence used by the caller.
                            val repairedReceipt = obtainConfirmation(fixture)
                            check(repairedReceipt.responderGuid == firstReceipt.responderGuid)
                            fixture.assertNoPairingMarker(GUID_A)
                            val retry = NikonCamera(fixture)
                            try {
                                retry.connectSta(
                                    ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                                    pairingConfirmation = repairedReceipt,
                                ).getOrThrow()
                                check(retry.staPairingConfirmed && retry.staAlbumAccessValidated)
                                check(fixture.pairingPrefs().getBoolean(STA_PAIRING_VERIFIED_MARKER_PREFIX + GUID_A, false))
                                val codes = server.commandCodes()
                                check(codes.count { it == PtpConstants.NK_PAIRING_QUERY } == 2)
                                check(codes.count { it == PtpConstants.NK_PAIRING_RESULT } == 2)
                                check(codes.count { it == Lab.NK_GET_LIVE_VIEW_IMG } == 1)
                                check(codes.count { it == Lab.NK_END_LIVE_VIEW } == 1)
                            } finally { retry.close() }
                            server.awaitFinished()
                            check(server.initiators().distinct().size == 1)
                            if (staleTrusted) check(server.initiators().all { it == SAVED_INITIATOR })
                        }
                    }
                    passed += if (staleTrusted) "pairing-only invalidates stale trust; denied LV cannot bypass full repair"
                        else "failed permission check persists nothing; a fresh same-host repair plus valid frame succeeds"
                }

                withFixture { fixture ->
                    FakeStaServer(listOf(
                        SessionPlan(event = PairingEvent.FRESH_CHANGED),
                        SessionPlan(guid = GUID_B, expectsEventConnection = false),
                    )).use { server ->
                        val first = NikonCamera(fixture)
                        val receipt = try {
                            val result = first.connectSta(
                                ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                            )
                            (result.exceptionOrNull() as? PairingCompletedException)?.confirmation
                                ?: error("Missing receipt for GUID binding test: ${result.exceptionOrNull()}")
                        } finally { first.close() }
                        val wrongCamera = NikonCamera(fixture)
                        try {
                            val result = wrongCamera.connectSta(
                                ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                                pairingConfirmation = receipt,
                            )
                            check(result.isFailure) { "A different camera accepted the first camera's receipt" }
                            check(!wrongCamera.staPairingConfirmed && !wrongCamera.staAlbumAccessValidated)
                            fixture.assertNoPairingMarker(GUID_A)
                            fixture.assertNoPairingMarker(GUID_B)
                        } finally { wrongCamera.close() }
                        server.awaitFinished()
                    }
                }
                passed += "receipt cannot confirm another responder GUID"

                withFixture { fixture ->
                    FakeStaServer(listOf(
                        SessionPlan(event = PairingEvent.FRESH_CHANGED),
                        SessionPlan(pairingOnlyDeviceInfo = true),
                    )).use { server ->
                        val receipt = obtainConfirmation(fixture)
                        val reconnect = NikonCamera(fixture)
                        try {
                            val result = reconnect.connectSta(
                                ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                                pairingConfirmation = receipt,
                            )
                            check(result.exceptionOrNull() is PairingNotConfirmedException) {
                                "Pairing-only reconnect must fail even after a valid event: ${result.exceptionOrNull()}"
                            }
                            check(!reconnect.staPairingConfirmed && !reconnect.staAlbumAccessValidated)
                            fixture.assertNoPairingMarker(GUID_A)
                            check(server.commandCodes().count { it == PtpConstants.NK_PAIRING_RESULT } == 1)
                        } finally { reconnect.close() }
                        server.awaitFinished()
                    }
                }
                passed += "receipt still requires a non-pairing-only reconnect"

                withFixture { fixture ->
                    fixture.pairingPrefs().edit()
                        .putString("initiator_id", SAVED_INITIATOR)
                        .putBoolean(STA_PAIRING_MARKER_PREFIX + GUID_A, true).commit()
                    FakeStaServer(listOf(SessionPlan(deviceInfoResponse = PtpConstants.DEVICE_BUSY))).use { server ->
                        val camera = NikonCamera(fixture)
                        try {
                            val result = camera.connectSta(
                                ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                            )
                            check(result.exceptionOrNull() is PairingNotConfirmedException)
                            check(!camera.staAlbumAccessValidated)
                            check(fixture.pairingPrefs().getBoolean(STA_PAIRING_MARKER_PREFIX + GUID_A, false)) {
                                "A temporary DeviceInfo failure erased the saved pairing"
                            }
                            check(fixture.pairingPrefs().getString("initiator_id", null) == SAVED_INITIATOR)
                            check(!fixture.pairingPrefs().getBoolean(STA_PAIRING_VERIFIED_MARKER_PREFIX + GUID_A, false))
                            check(server.commandCodes().none {
                                it == PtpConstants.NK_PAIRING_QUERY || it == PtpConstants.NK_PAIRING_RESULT
                            })
                        } finally { camera.close() }
                        server.awaitFinished()
                    }
                }
                passed += "temporary DeviceInfo failure preserves legacy credentials"

                withFixture { fixture ->
                    FakeStaServer(listOf(SessionPlan(event = PairingEvent.GATED_FRESH_CHANGED))).use { server ->
                        val camera = NikonCamera(fixture)
                        try {
                            coroutineScope {
                                val connection = async(Dispatchers.Default) {
                                    camera.connectSta(
                                        ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                                    )
                                }
                                server.awaitPairingResult()
                                connection.cancel()
                                server.releaseConfirmation()
                                var cancelled = false
                                try { connection.await() } catch (_: CancellationException) { cancelled = true }
                                check(cancelled) { "Cancelled pairing returned a successful receipt" }
                            }
                            check(!camera.staPairingConfirmed && !camera.staAlbumAccessValidated)
                            fixture.assertNoPairingMarker(GUID_A)
                        } finally {
                            server.releaseConfirmation()
                            camera.close()
                        }
                        server.awaitFinished()
                    }
                }
                passed += "cancellation rejects a late state-change event"

                for (trusted in listOf(true, false)) {
                    withFixture { fixture ->
                        fixture.pairingPrefs().edit()
                            .putString("initiator_id", SAVED_INITIATOR)
                            .putBoolean(STA_PAIRING_MARKER_PREFIX + GUID_A, true)
                            .apply {
                                if (trusted) putBoolean(STA_PAIRING_VERIFIED_MARKER_PREFIX + GUID_A, true)
                            }.commit()
                        FakeStaServer(listOf(SessionPlan(liveView = LiveViewCase.UNSUPPORTED))).use { server ->
                            val camera = NikonCamera(fixture)
                            try {
                                camera.connectSta(
                                    ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                                ).getOrThrow()
                                check(camera.staPairingConfirmed && camera.staAlbumAccessValidated)
                                check(server.commandCodes().none {
                                    it == PtpConstants.NK_PAIRING_QUERY || it == PtpConstants.NK_PAIRING_RESULT
                                }) { "An existing ${if (trusted) "v2" else "legacy"} pairing was repeated" }
                                check(server.commandCodes().none { it in LIVE_VIEW_COMMANDS }) {
                                    "Saved pairing unexpectedly required monitor support"
                                }
                                check(fixture.pairingPrefs().getString("initiator_id", null) == SAVED_INITIATOR)
                                check(fixture.pairingPrefs().getBoolean(STA_PAIRING_MARKER_PREFIX + GUID_A, false))
                            } finally { camera.close() }
                            server.awaitFinished()
                            check(server.initiators() == listOf(SAVED_INITIATOR))
                        }
                    }
                    passed += "${if (trusted) "v2" else "legacy"} saved pairing reuses its original identity"
                }
            }
            report.putString("result", "PASS (${passed.size} scenarios):\n" + passed.joinToString("\n"))
            finish(Activity.RESULT_OK, report)
        } catch (error: Throwable) {
            report.putString("passed", passed.joinToString("\n"))
            report.putString("failure", error.stackTraceToString())
            finish(Activity.RESULT_CANCELED, report)
        }
    }

    private suspend fun withFixture(block: suspend (FixtureContext) -> Unit) {
        val fixture = FixtureContext(targetContext)
        try { block(fixture) } finally { fixture.cleanup() }
    }

    private suspend fun obtainConfirmation(fixture: FixtureContext): StaPairingConfirmation {
        val camera = NikonCamera(fixture)
        return try {
            val result = camera.connectSta(ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true)
            (result.exceptionOrNull() as? PairingCompletedException)?.confirmation
                ?: error("Missing first-pairing confirmation: ${result.exceptionOrNull()}\n${camera.staDiagnosticReport}")
        } finally { camera.close() }
    }

    private class FixtureContext(base: Context) : ContextWrapper(base) {
        private val prefix = "sta_pairing_fixture_${System.nanoTime()}_"
        private val names = Collections.synchronizedSet(mutableSetOf<String>())
        override fun getApplicationContext(): Context = this
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
            super.getSharedPreferences(prefix + name, mode).also { names += prefix + name }
        fun pairingPrefs(): SharedPreferences = getSharedPreferences(PTPIP_IDENTITY_PREFERENCES, Context.MODE_PRIVATE)
        fun assertNoPairingMarker(guid: String) {
            check(!pairingPrefs().getBoolean(STA_PAIRING_MARKER_PREFIX + guid, false))
            check(!pairingPrefs().getBoolean(STA_PAIRING_VERIFIED_MARKER_PREFIX + guid, false))
        }
        fun cleanup() { names.toList().forEach { baseContext.deleteSharedPreferences(it) } }
    }

    private enum class PairingEvent {
        EOF, UNRELATED_THEN_EOF, SHORT_CHANGED_THEN_EOF, STALE_CHANGED_THEN_EOF,
        TIMEOUT_CONNECTED, FRESH_CHANGED, GATED_FRESH_CHANGED,
    }
    private enum class LiveViewCase {
        NORMAL, START_EOF, FRAME_EOF, START_DENIED, BAD_FRAME, END_DENIED,
        ALREADY_ACTIVE, BUSY_THEN_READY, GATED_FRAME, UNSUPPORTED,
    }
    private data class SessionPlan(
        val guid: String = GUID_A,
        val event: PairingEvent? = null,
        val expectsEventConnection: Boolean = true,
        val pairingOnlyDeviceInfo: Boolean = false,
        val deviceInfoResponse: Int = PtpConstants.RESPONSE_OK,
        val liveView: LiveViewCase = LiveViewCase.NORMAL,
    )

    private class FakeStaServer(private val plans: List<SessionPlan>) : Closeable {
        private val listener = ServerSocket().apply {
            reuseAddress = true
            bind(InetSocketAddress(InetAddress.getByName(LOOPBACK), PtpConstants.PTP_PORT))
            soTimeout = 8_000
        }
        private val sockets = Collections.synchronizedList(mutableListOf<Socket>())
        private val commands = Collections.synchronizedList(mutableListOf<Int>())
        private val hosts = Collections.synchronizedList(mutableListOf<String>())
        private val failure = AtomicReference<Throwable?>()
        private val resultSent = CountDownLatch(1)
        private val confirmationAllowed = CountDownLatch(1)
        private val frameRequested = CountDownLatch(1)
        private val frameAllowed = CountDownLatch(1)
        private val liveViewEnded = CountDownLatch(1)
        @Volatile private var stopping = false
        private val worker = thread(name = "sta-pairing-fixture", isDaemon = true) {
            try { plans.forEach(::serveSession) }
            catch (error: Throwable) { if (!stopping) failure.set(error) }
        }

        fun commandCodes(): List<Int> = synchronized(commands) { commands.toList() }
        fun initiators(): List<String> = synchronized(hosts) { hosts.toList() }
        fun awaitPairingResult() { check(resultSent.await(8, TimeUnit.SECONDS)) { "Pairing Result was never sent" } }
        fun releaseConfirmation() { confirmationAllowed.countDown() }
        fun awaitFrameRequest() { check(frameRequested.await(8, TimeUnit.SECONDS)) { "A frame was never requested" } }
        fun releaseFrame() { frameAllowed.countDown() }
        fun awaitLiveViewEnd() { check(liveViewEnded.await(8, TimeUnit.SECONDS)) { "Live View cleanup was never completed" } }
        fun awaitFinished() {
            worker.join(3_000)
            check(!worker.isAlive) { "Synthetic camera did not finish its expected sessions" }
            failure.get()?.let { throw AssertionError("Synthetic camera failed", it) }
        }
        override fun close() {
            stopping = true
            confirmationAllowed.countDown()
            frameAllowed.countDown()
            listener.close()
            synchronized(sockets) { sockets.forEach { runCatching { it.close() } } }
            worker.join(3_000)
        }

        private fun accept(): Socket = listener.accept().apply {
            tcpNoDelay = true
            // The production first-pairing event timeout is 30 seconds; this peer must not
            // manufacture an earlier command-channel EOF in the genuine timeout scenario.
            soTimeout = 45_000
            sockets += this
        }

        private fun serveSession(plan: SessionPlan) {
            val command = accept()
            val input = command.getInputStream()
            val output = command.getOutputStream()
            val init = readPacket(input)
            check(init.type == PtpConstants.INIT_CMD_REQ && init.payload.size >= 16)
            hosts += init.payload.copyOfRange(0, 16).toString(Charsets.US_ASCII)
            output.packet(PtpConstants.INIT_CMD_ACK, bytes {
                u32(1); raw(plan.guid.chunked(2).map { it.toInt(16).toByte() }.toByteArray())
                raw("STA fixture".toByteArray(Charsets.UTF_16LE)); u16(0); u32(0x00010000)
            })
            if (!plan.expectsEventConnection) {
                check(input.read() == -1) { "Wrong responder was used beyond InitCommandAck" }
                command.close()
                return
            }
            val events = accept()
            check(readPacket(events.getInputStream()).type == PtpConstants.INIT_EVT_REQ)
            val eventOutput = events.getOutputStream()
            eventOutput.packet(PtpConstants.INIT_EVT_ACK)
            var readyCalls = 0
            var frameCalls = 0
            while (true) {
                val request = try { readPacket(input) } catch (_: EOFException) { break }
                if (request.type == PtpConstants.PONG) continue
                check(request.type == PtpConstants.CMD_REQUEST && request.payload.size >= 10)
                val code = request.payload.u16(4)
                val transaction = request.payload.i32(6)
                commands += code
                when (code) {
                    PtpConstants.OPEN_SESSION, 0x941C, PtpConstants.CLOSE_SESSION -> output.response(transaction)
                    PtpConstants.GET_STORAGE_IDS -> output.response(transaction, bytes { u32(1); u32(0x00010001) })
                    PtpConstants.GET_DEVICE_INFO -> output.response(
                        transaction,
                        deviceInfo(plan.pairingOnlyDeviceInfo, plan.liveView != LiveViewCase.UNSUPPORTED).takeIf { plan.deviceInfoResponse == PtpConstants.RESPONSE_OK },
                        plan.deviceInfoResponse,
                    )
                    PtpConstants.GET_OBJECT_HANDLES -> output.response(transaction, bytes { u32(1); u32(0x00010001) })
                    // The production bounded access probe checks response success and ObjectInfo size.
                    PtpConstants.GET_OBJECT_INFO -> output.response(transaction, ByteArray(64))
                    Lab.GET_DEVICE_PROP_VALUE -> {
                        check(request.payload.size >= 14 && request.payload.i32(10) == Lab.PROP_NK_LV_STATUS)
                        check(plan.liveView != LiveViewCase.UNSUPPORTED) { "Saved pairing read LV status" }
                        output.response(transaction, byteArrayOf(if (plan.liveView == LiveViewCase.ALREADY_ACTIVE) 1 else 0))
                    }
                    Lab.NK_START_LIVE_VIEW -> {
                        check(plan.liveView != LiveViewCase.UNSUPPORTED)
                        check(plan.liveView != LiveViewCase.ALREADY_ACTIVE) { "Restarted an existing monitor" }
                        if (plan.liveView == LiveViewCase.START_EOF) {
                            events.close()
                            command.close()
                            return
                        }
                        output.response(transaction, responseCode = if (plan.liveView == LiveViewCase.START_DENIED) Lab.ACCESS_DENIED else Lab.OK)
                    }
                    Lab.NK_DEVICE_READY -> {
                        check(plan.liveView != LiveViewCase.UNSUPPORTED)
                        output.response(transaction, responseCode =
                            if (plan.liveView == LiveViewCase.BUSY_THEN_READY && readyCalls++ == 0) Lab.DEVICE_BUSY else Lab.OK)
                    }
                    Lab.NK_GET_LIVE_VIEW_IMG -> {
                        check(plan.liveView != LiveViewCase.UNSUPPORTED)
                        if (plan.liveView == LiveViewCase.FRAME_EOF) {
                            events.close()
                            command.close()
                            return
                        }
                        if (plan.liveView == LiveViewCase.GATED_FRAME) {
                            frameRequested.countDown()
                            check(frameAllowed.await(8, TimeUnit.SECONDS)) { "Valid frame was not released" }
                        }
                        if (plan.liveView == LiveViewCase.BUSY_THEN_READY && frameCalls++ == 0) {
                            output.response(transaction, responseCode = Lab.DEVICE_BUSY)
                        } else {
                            output.response(transaction, if (plan.liveView == LiveViewCase.BAD_FRAME)
                                byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0, 0, 0xFF.toByte(), 0xD9.toByte()) else VALID_LIVE_VIEW_FRAME)
                        }
                    }
                    Lab.NK_END_LIVE_VIEW -> {
                        check(plan.liveView !in listOf(LiveViewCase.UNSUPPORTED, LiveViewCase.ALREADY_ACTIVE, LiveViewCase.START_DENIED, LiveViewCase.START_EOF, LiveViewCase.FRAME_EOF))
                        output.response(transaction, responseCode = if (plan.liveView == LiveViewCase.END_DENIED) Lab.ACCESS_DENIED else Lab.OK)
                        liveViewEnded.countDown()
                    }
                    PtpConstants.NK_PAIRING_QUERY -> {
                        check(plan.event != null) { "Existing pairing unexpectedly sent a query" }
                        if (plan.event == PairingEvent.STALE_CHANGED_THEN_EOF) {
                            eventOutput.packet(PtpConstants.EVENT, event(PtpConstants.EVENT_DEVICE_INFO_CHANGED, transaction))
                            // Ensure this was already queued before Query completes, not a new result event.
                            Thread.sleep(40)
                        }
                        output.response(transaction, bytes { u32(0) })
                    }
                    PtpConstants.NK_PAIRING_RESULT -> {
                        check(request.payload.size >= 14 && request.payload.i32(10) == PtpConstants.RESPONSE_OK)
                        output.response(transaction)
                        resultSent.countDown()
                        when (checkNotNull(plan.event)) {
                            PairingEvent.FRESH_CHANGED -> eventOutput.packet(PtpConstants.EVENT,
                                event(PtpConstants.EVENT_DEVICE_INFO_CHANGED, transaction))
                            PairingEvent.UNRELATED_THEN_EOF -> eventOutput.packet(PtpConstants.EVENT,
                                event(0x4002, transaction))
                            PairingEvent.SHORT_CHANGED_THEN_EOF -> eventOutput.packet(PtpConstants.EVENT,
                                bytes { u16(PtpConstants.EVENT_DEVICE_INFO_CHANGED) })
                            PairingEvent.GATED_FRESH_CHANGED -> {
                                check(confirmationAllowed.await(8, TimeUnit.SECONDS)) { "Late event was not released" }
                                try {
                                    eventOutput.packet(PtpConstants.EVENT, event(PtpConstants.EVENT_DEVICE_INFO_CHANGED, transaction))
                                } catch (_: SocketException) {
                                    // Cancellation may close the transport before the late packet reaches it.
                                }
                            }
                            else -> Unit
                        }
                        if (plan.event !in setOf(PairingEvent.FRESH_CHANGED, PairingEvent.GATED_FRESH_CHANGED,
                                PairingEvent.TIMEOUT_CONNECTED)) events.close()
                    }
                    else -> error("Unexpected STA handshake command 0x${code.toString(16)}")
                }
            }
            events.close()
            command.close()
        }
    }

    private data class Packet(val type: Int, val payload: ByteArray)
    private companion object {
        const val LOOPBACK = "127.0.0.1"
        const val GUID_A = "00112233445566778899aabbccddeeff"
        const val GUID_B = "102132435465768798a9bacbdcedfe0f"
        const val SAVED_INITIATOR = "1234567890abcdef"
        val LIVE_VIEW_COMMANDS = setOf(Lab.GET_DEVICE_PROP_VALUE, Lab.NK_START_LIVE_VIEW,
            Lab.NK_DEVICE_READY, Lab.NK_GET_LIVE_VIEW_IMG, Lab.NK_END_LIVE_VIEW)
        val VALID_LIVE_VIEW_FRAME: ByteArray by lazy {
            val image = Bitmap.createBitmap(16, 12, Bitmap.Config.ARGB_8888)
            try {
                image.eraseColor(Color.rgb(40, 90, 150))
                ByteArray(384) + ByteArrayOutputStream().also {
                    check(image.compress(Bitmap.CompressFormat.JPEG, 90, it))
                }.toByteArray()
            } finally { image.recycle() }
        }

        fun awaitBlockedPairingCommit() {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(8)
            do {
                if (Thread.getAllStackTraces().any { (thread, stack) ->
                        thread.state == Thread.State.BLOCKED && stack.any {
                            it.className == NikonCamera::class.java.name &&
                                it.methodName == "confirmPairingIfNeeded"
                        }
                    }) return
                Thread.yield()
            } while (System.nanoTime() < deadline)
            error("Final pairing commit did not wait for the reset lock")
        }

        fun readPacket(input: InputStream): Packet {
            val header = readFully(input, 8)
            val length = header.i32(0)
            check(length in 8..1_048_576)
            return Packet(header.i32(4), readFully(input, length - 8))
        }
        fun readFully(input: InputStream, count: Int): ByteArray {
            val result = ByteArray(count)
            var offset = 0
            while (offset < count) {
                val read = input.read(result, offset, count - offset)
                if (read < 0) throw EOFException()
                offset += read
            }
            return result
        }
        fun OutputStream.packet(type: Int, payload: ByteArray = byteArrayOf()) {
            write(bytes { u32(payload.size + 8); u32(type); raw(payload) })
            flush()
        }
        fun OutputStream.response(transaction: Int, data: ByteArray? = null, responseCode: Int = PtpConstants.RESPONSE_OK) {
            if (data != null) {
                packet(PtpConstants.START_DATA_PACKET, bytes { u32(transaction); u32(data.size); u32(0) })
                packet(PtpConstants.END_DATA_PACKET, bytes { u32(transaction); raw(data) })
            }
            packet(PtpConstants.CMD_RESPONSE, bytes { u16(responseCode); u32(transaction) })
        }
        fun event(code: Int, transaction: Int) = bytes { u16(code); u32(transaction) }
        fun deviceInfo(pairingOnly: Boolean, liveViewSupported: Boolean) = bytes {
            u16(100); u32(10); u16(100); ptpString(""); u16(0)
            // Nikon's paired transfer profile may keep all five pairing codes plus GetVendorCodes;
            // it must not be misclassified as a new pairing merely because those codes remain.
            u16Array(listOf(PtpConstants.GET_DEVICE_INFO, PtpConstants.OPEN_SESSION, PtpConstants.CLOSE_SESSION,
                PtpConstants.NK_PAIRING_QUERY, PtpConstants.NK_PAIRING_RESULT) +
                if (pairingOnly) emptyList() else listOf(0x9439) +
                    if (liveViewSupported) LIVE_VIEW_COMMANDS.toList() else emptyList())
            u16Array(listOf(PtpConstants.EVENT_DEVICE_INFO_CHANGED))
            u16Array(emptyList()); u16Array(emptyList()); u16Array(listOf(0x3801))
            ptpString("Nikon"); ptpString("STA fixture"); ptpString("1.00"); ptpString("fixture-serial")
        }
        fun bytes(block: Encoder.() -> Unit): ByteArray = Encoder().apply(block).toByteArray()
        fun ByteArray.u16(offset: Int) = (this[offset].toInt() and 255) or ((this[offset + 1].toInt() and 255) shl 8)
        fun ByteArray.i32(offset: Int) = u16(offset) or (u16(offset + 2) shl 16)
    }

    private class Encoder : ByteArrayOutputStream() {
        fun u16(value: Int) { write(value and 255); write((value ushr 8) and 255) }
        fun u32(value: Int) { u16(value); u16(value ushr 16) }
        fun raw(value: ByteArray) { write(value) }
        fun u16Array(values: List<Int>) { u32(values.size); values.forEach(::u16) }
        fun ptpString(value: String) {
            if (value.isEmpty()) write(0)
            else { write(value.length + 1); raw(value.toByteArray(Charsets.UTF_16LE)); u16(0) }
        }
    }
}
