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
import android.os.SystemClock
import com.ztransfer.diagnostics.StaPairingPropertyProbe
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
import java.net.SocketTimeoutException
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
    private var diagnosticOnly = false
    private var recoveryOnly = false
    override fun onCreate(arguments: Bundle?) {
        diagnosticOnly = arguments?.getString("diagnosticOnly") == "true"
        recoveryOnly = arguments?.getString("recoveryOnly") == "true"
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val report = Bundle()
        val passed = mutableListOf<String>()
        try {
            check(Build.FINGERPRINT.contains("generic") || Build.MODEL.contains("sdk", true)) {
                "The synthetic STA pairing server is emulator-only"
            }
            check((targetContext.getSystemService(Context.USB_SERVICE) as UsbManager).deviceList.isEmpty())
            runBlocking {
                if (recoveryOnly) {
                    verifyProbeRecovery(passed)
                    return@runBlocking
                }
                for (failProbe in listOf(false, true)) {
                    withFixture { fixture ->
                        FakeStaServer(listOf(SessionPlan(liveView = LiveViewCase.UNSUPPORTED))).use { server ->
                            val camera = NikonCamera(fixture)
                            try {
                                val result = camera.connectStaProbe(
                                    ip = LOOPBACK,
                                    body = { session ->
                                        check(session.isStaProbeSessionActive())
                                        check(!NikonCamera(fixture).isStaProbeSessionActive())
                                        session.sendCmd(0x941C)
                                        check(session.recvRespWithPayload().first == Lab.OK)
                                        if (failProbe) throw java.io.IOException("controlled diagnostic failure")
                                    },
                                )
                                check(!camera.isStaProbeSessionActive())
                                check(result.isSuccess == !failProbe)
                                check(!camera.staAlbumAccessValidated && !camera.staPairingConfirmed)
                                fixture.assertNoPairingMarker(GUID_A)
                            } finally { camera.abortStaConnectionAttempt() }
                            server.awaitFinished()
                            check(server.commandCodes() == listOf(PtpConstants.OPEN_SESSION, 0x941C)) {
                                "Diagnostic session ran production commands: ${server.commandCodes()}"
                            }
                        }
                    }
                    passed += "diagnostic failure=$failProbe cannot activate, persist, pair or close a bad stream"
                }
                if (diagnosticOnly) return@runBlocking
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
                                val completion = result.exceptionOrNull() as? PairingCompletedException
                                    ?: error("Complete Result ACK must yield a pending receipt despite $event: ${result.exceptionOrNull()}")
                                check(!completion.isRecovery)
                                check(completion.confirmation.resultAcknowledgedAtMs in 1..SystemClock.elapsedRealtime())
                                check(!completion.confirmation.remotePermissionVerified)
                                check(!camera.staPairingConfirmed && !camera.staAlbumAccessValidated)
                                check(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt) < 3_000) {
                                    "Result ACK unnecessarily waited for an event or CloseSession"
                                }
                                check(PtpConstants.CLOSE_SESSION !in server.commandCodes())
                                fixture.assertNoPairingMarker(GUID_A)
                                check(server.commandCodes().count { it == PtpConstants.NK_PAIRING_QUERY } == 1)
                                check(server.commandCodes().count { it == PtpConstants.NK_PAIRING_RESULT } == 1)
                            } finally { camera.close() }
                            server.awaitFinished()
                        }
                    }
                    passed += "Result ACK with $event produces only a pending receipt without event waiting, CloseSession or trust"
                }

                withFixture { fixture ->
                    FakeStaServer(listOf(
                        SessionPlan(event = PairingEvent.TIMEOUT_CONNECTED),
                        SessionPlan(),
                    )).use { server ->
                        val first = NikonCamera(fixture)
                        val receipt = try {
                            val result = first.connectSta(
                                ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                            )
                            val completion = result.exceptionOrNull() as? PairingCompletedException
                                ?: error("Complete Result ACK did not yield a receipt: ${result.exceptionOrNull()}\n" +
                                    first.staDiagnosticReport)
                            check(completion.confirmation.responderGuid == GUID_A)
                            check(!completion.isRecovery && !completion.confirmation.remotePermissionVerified)
                            check(completion.confirmation.resultAcknowledgedAtMs in 1..SystemClock.elapsedRealtime())
                            check(PtpConstants.CLOSE_SESSION !in server.commandCodes())
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
                passed += "Result ACK without an event plus same-camera valid frame persists pairing"

                for (operation in listOf(PtpConstants.NK_PAIRING_QUERY, PtpConstants.NK_PAIRING_RESULT)) {
                    for (eof in listOf(false, true)) {
                        withFixture { fixture ->
                            val plan = if (eof) {
                                SessionPlan(event = PairingEvent.TIMEOUT_CONNECTED,
                                    stalledOperation = operation, stalledReply = StalledReply.EOF)
                            } else {
                                SessionPlan(event = PairingEvent.TIMEOUT_CONNECTED,
                                    pairingQueryResponse = if (operation == PtpConstants.NK_PAIRING_QUERY) Lab.ACCESS_DENIED else Lab.OK,
                                    pairingResultResponse = if (operation == PtpConstants.NK_PAIRING_RESULT) Lab.ACCESS_DENIED else Lab.OK)
                            }
                            FakeStaServer(listOf(plan)).use { server ->
                                val camera = NikonCamera(fixture)
                                try {
                                    val result = camera.connectSta(
                                        ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                                    )
                                    check(result.isFailure && result.exceptionOrNull() !is PairingCompletedException)
                                    if (!eof) check(result.exceptionOrNull() is StaResponseException)
                                    check(!camera.staPairingConfirmed && !camera.staAlbumAccessValidated)
                                    fixture.assertNoPairingMarker(GUID_A)
                                    check(server.commandCodes().last() == operation)
                                    check(PtpConstants.CLOSE_SESSION !in server.commandCodes())
                                } finally { camera.close() }
                                server.awaitFinished()
                            }
                        }
                        passed += "pairing 0x${operation.toString(16)} ${if (eof) "EOF" else "rejection"} cannot yield a receipt, trust or CloseSession"
                    }
                }

                for (stillPairingOnly in listOf(false, true)) {
                    withFixture { fixture ->
                        FakeStaServer(listOf(
                            SessionPlan(event = PairingEvent.TIMEOUT_CONNECTED),
                            SessionPlan(event = PairingEvent.TIMEOUT_CONNECTED, pairingOnlyDeviceInfo = true,
                                liveView = LiveViewCase.UNSUPPORTED),
                            SessionPlan(pairingOnlyDeviceInfo = stillPairingOnly,
                                liveView = if (stillPairingOnly) LiveViewCase.UNSUPPORTED else LiveViewCase.NORMAL),
                        )).use { server ->
                            val receipt = obtainConfirmation(fixture)
                            val repair = NikonCamera(fixture)
                            val repairedReceipt = try {
                                val result = repair.connectSta(
                                    ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                                    pairingConfirmation = receipt, allowInlinePairingRecovery = true,
                                )
                                val completed = result.exceptionOrNull() as? PairingCompletedException
                                    ?: error("Pairing-only reconnect did not repair in its existing session: ${result.exceptionOrNull()}")
                                check(completed.isRecovery)
                                check(completed.confirmation.responderGuid == receipt.responderGuid)
                                check(!completed.confirmation.remotePermissionVerified)
                                check(completed.confirmation.resultAcknowledgedAtMs >= receipt.resultAcknowledgedAtMs)
                                check(!repair.staPairingConfirmed && !repair.staAlbumAccessValidated)
                                fixture.assertNoPairingMarker(GUID_A)
                                check(server.commandCodes().none { it in LIVE_VIEW_COMMANDS || it == PtpConstants.CLOSE_SESSION })
                                completed.confirmation
                            } finally { repair.close() }
                            val reconnect = NikonCamera(fixture)
                            try {
                                val result = reconnect.connectSta(
                                    ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                                    pairingConfirmation = repairedReceipt, allowInlinePairingRecovery = false,
                                )
                                if (stillPairingOnly) {
                                    val error = result.exceptionOrNull() as? PairingNotConfirmedException
                                        ?: error("Repeated pairing-only state did not stop: ${result.exceptionOrNull()}")
                                    check(error.pairingOnly && !error.remoteRequestAttempted)
                                    check(!reconnect.staPairingConfirmed && !reconnect.staAlbumAccessValidated)
                                    fixture.assertNoPairingMarker(GUID_A)
                                    check(server.commandCodes().none { it in LIVE_VIEW_COMMANDS })
                                } else {
                                    result.getOrThrow()
                                    check(reconnect.staPairingConfirmed && reconnect.staAlbumAccessValidated)
                                    check(fixture.pairingPrefs().getBoolean(STA_PAIRING_VERIFIED_MARKER_PREFIX + GUID_A, false))
                                    check(server.commandCodes().count { it == Lab.NK_GET_LIVE_VIEW_IMG } == 1)
                                }
                                check(server.commandCodes().count { it == PtpConstants.NK_PAIRING_QUERY } == 2)
                                check(server.commandCodes().count { it == PtpConstants.NK_PAIRING_RESULT } == 2)
                            } finally { reconnect.close() }
                            server.awaitFinished()
                            check(server.initiators().size == 3 && server.initiators().distinct().size == 1)
                        }
                    }
                    passed += if (stillPairingOnly) "inline repair is consumed once; persistent pairing-only state stops without monitor or more pairing"
                        else "pending receipt repairs pairing-only state in the open session; only later valid frame establishes trust"
                }

                for ((operation, stall) in listOf(
                    PtpConstants.NK_PAIRING_QUERY to StalledReply.PINGS,
                    PtpConstants.NK_PAIRING_RESULT to StalledReply.TRICKLED_PACKET,
                )) {
                    withFixture { fixture ->
                        FakeStaServer(listOf(SessionPlan(
                            event = PairingEvent.FRESH_CHANGED, stalledOperation = operation, stalledReply = stall,
                        ))).use { server ->
                            val camera = NikonCamera(fixture)
                            try {
                                val startedAt = System.nanoTime()
                                val result = camera.connectSta(
                                    ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                                )
                                val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt)
                                check(result.exceptionOrNull() is SocketTimeoutException) {
                                    "$stall must reach the response deadline: ${result.exceptionOrNull()}\n${camera.staDiagnosticReport}"
                                }
                                check(elapsedMs in 4_500..7_000) { "$stall stalled for ${elapsedMs}ms" }
                                check(server.commandCodes().last() == operation) {
                                    "Deadline test failed before its intended command"
                                }
                                check(!camera.staPairingConfirmed && !camera.staAlbumAccessValidated)
                                fixture.assertNoPairingMarker(GUID_A)
                                check(PtpConstants.CLOSE_SESSION !in server.commandCodes()) {
                                    "Timed-out/partial command input was reused for CloseSession"
                                }
                            } finally { camera.close() }
                            server.awaitFinished()
                        }
                    }
                    passed += "$stall cannot extend a pairing response deadline or reuse its timed-out stream"
                }

                for (closeReply in listOf(CloseReply.SILENT, CloseReply.PARTIAL_PACKET)) {
                    withFixture { fixture ->
                        FakeStaServer(listOf(
                            SessionPlan(event = PairingEvent.FRESH_CHANGED, closeReply = closeReply),
                            SessionPlan(),
                        )).use { server ->
                            val startedAt = System.nanoTime()
                            val phases = mutableListOf<String>()
                            val first = NikonCamera(fixture)
                            val receipt = try {
                                val result = first.connectSta(
                                    ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                                    onPairingStarted = { phases += "pairing" },
                                    onConnectingStarted = {
                                        check(PtpConstants.CLOSE_SESSION !in server.commandCodes()) {
                                            "Connecting status was deferred until after old-session cleanup"
                                        }
                                        phases += "connecting"
                                    },
                                )
                                check(phases == listOf("pairing", "connecting")) { "Wrong phase order: $phases" }
                                (result.exceptionOrNull() as? PairingCompletedException)?.confirmation
                                    ?: error("Missing receipt after $closeReply: ${result.exceptionOrNull()}")
                            } finally { first.close() }
                            check(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt) < 3_000) {
                                "$closeReply unnecessarily waited for CloseSession after Result ACK"
                            }
                            check(PtpConstants.CLOSE_SESSION !in server.commandCodes()) {
                                "$closeReply sent CloseSession while the camera was restarting"
                            }
                            fixture.assertNoPairingMarker(GUID_A)
                            val camera = NikonCamera(fixture)
                            try {
                                camera.connectSta(
                                    ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                                    pairingConfirmation = receipt,
                                ).getOrThrow()
                                check(camera.staPairingConfirmed && camera.staAlbumAccessValidated)
                                check(fixture.pairingPrefs().getBoolean(STA_PAIRING_VERIFIED_MARKER_PREFIX + GUID_A, false))
                                check(Lab.NK_GET_LIVE_VIEW_IMG in server.commandCodes())
                            } finally { camera.close() }
                            server.awaitFinished()
                            check(server.commandCodes().count { it == PtpConstants.CLOSE_SESSION } == 1) {
                                "Only the verified browsing session may send CloseSession"
                            }
                            check(server.initiators().distinct().size == 1)
                        }
                    }
                    passed += "$closeReply is never read after Result ACK; same-body frame still required"
                }

                for (deniedSample in listOf(-1, 0, 1, 2)) {
                    withFixture { fixture ->
                        val handles = (0x00010001..0x00010005).toList()
                        val samples = listOf(handles.first(), handles[2], handles.last())
                        FakeStaServer(listOf(
                            SessionPlan(event = PairingEvent.FRESH_CHANGED),
                            SessionPlan(objectHandles = handles,
                                deniedObjectInfoHandle = samples.getOrNull(deniedSample)),
                        )).use { server ->
                            val receipt = obtainConfirmation(fixture)
                            val camera = NikonCamera(fixture)
                            try {
                                camera.connectSta(
                                    ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                                    pairingConfirmation = receipt,
                                ).getOrThrow()
                                check(camera.staPairingConfirmed && camera.staAlbumAccessValidated)
                                check(camera.staDirectObjectReadValidated == (deniedSample >= 0))
                                val codes = server.commandCodes()
                                check(codes.count { it == PtpConstants.GET_OBJECT_INFO } ==
                                    if (deniedSample < 0) 3 else deniedSample + 1) {
                                    "ObjectInfo sampling must stop at the first failed sample; commands=$codes"
                                }
                                check(PtpConstants.GET_THUMB !in codes) {
                                    "Album validation must not request an unused thumbnail"
                                }
                                check(codes.count { it == PtpConstants.NK_GET_OBJECT_SIZE } ==
                                    if (deniedSample < 0) 0 else 1)
                                check(codes.count { it == PtpConstants.NK_GET_PARTIAL_OBJECT_EX } ==
                                    if (deniedSample < 0) 0 else 1)
                                check(Lab.NK_GET_LIVE_VIEW_IMG in codes) {
                                    "Direct object access must still require fresh-pairing monitor verification"
                                }
                                check(fixture.pairingPrefs().getBoolean(STA_PAIRING_VERIFIED_MARKER_PREFIX + GUID_A, false))
                            } finally { camera.close() }
                            server.awaitFinished()
                        }
                    }
                    passed += if (deniedSample < 0) "fully readable album retains all three ObjectInfo samples"
                        else "denied ObjectInfo sample $deniedSample skips remaining samples and unused thumbnail"
                }

                withFixture { fixture ->
                    FakeStaServer(listOf(
                        SessionPlan(event = PairingEvent.FRESH_CHANGED),
                        SessionPlan(objectHandles = (0x00010001..0x00010005).toList(),
                            deniedObjectInfoHandle = 0x00010001, liveView = LiveViewCase.START_DENIED),
                    )).use { server ->
                        val receipt = obtainConfirmation(fixture)
                        val camera = NikonCamera(fixture)
                        try {
                            val result = camera.connectSta(
                                ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                                pairingConfirmation = receipt,
                            )
                            check(result.exceptionOrNull() is PairingNotConfirmedException)
                            check(!camera.staPairingConfirmed)
                            fixture.assertNoPairingMarker(GUID_A)
                            val codes = server.commandCodes()
                            check(codes.count { it == PtpConstants.GET_OBJECT_INFO } == 1)
                            check(codes.count { it == PtpConstants.NK_GET_OBJECT_SIZE } == 1)
                            check(codes.count { it == PtpConstants.NK_GET_PARTIAL_OBJECT_EX } == 1)
                            check(PtpConstants.GET_THUMB !in codes)
                            check(Lab.NK_START_LIVE_VIEW in codes)
                        } finally { camera.close() }
                        server.awaitFinished()
                    }
                }
                passed += "direct album access cannot confirm pairing after the monitor permission check fails"

                for (sizeReply in listOf(ObjectSizeReply.DENIED, ObjectSizeReply.SHORT, ObjectSizeReply.ZERO)) {
                    withFixture { fixture ->
                        FakeStaServer(listOf(
                            SessionPlan(event = PairingEvent.FRESH_CHANGED),
                            SessionPlan(deniedObjectInfoHandle = 0x00010001, objectSizeReply = sizeReply),
                        )).use { server ->
                            val receipt = obtainConfirmation(fixture)
                            val camera = NikonCamera(fixture)
                            try {
                                val result = camera.connectSta(
                                    ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                                    pairingConfirmation = receipt,
                                )
                                check(result.isFailure)
                                check(!camera.staPairingConfirmed && !camera.staAlbumAccessValidated)
                                check(!camera.staDirectObjectReadValidated)
                                fixture.assertNoPairingMarker(GUID_A)
                                val codes = server.commandCodes()
                                check(codes.count { it == PtpConstants.NK_GET_OBJECT_SIZE } == 1)
                                check(PtpConstants.NK_GET_PARTIAL_OBJECT_EX !in codes) {
                                    "$sizeReply size cannot be repaired by reading object bytes"
                                }
                                check(codes.count { it == 0x9435 } == 1) {
                                    "Invalid direct size must preserve the application-mode compatibility attempt"
                                }
                                check(codes.none { it in LIVE_VIEW_COMMANDS })
                            } finally { camera.close() }
                            server.awaitFinished()
                        }
                    }
                    passed += "$sizeReply object size skips partial read and retains compatibility fallback without trust"
                }

                for (liveView in listOf(
                    LiveViewCase.START_EOF, LiveViewCase.FRAME_EOF, LiveViewCase.START_DENIED,
                    LiveViewCase.BAD_FRAME,
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
                                check((result.exceptionOrNull() as PairingNotConfirmedException).remoteRequestAttempted)
                                check(!(result.exceptionOrNull() as PairingNotConfirmedException).pairingOnly)
                                check(!camera.staPairingConfirmed)
                                fixture.assertNoPairingMarker(GUID_A)
                                val ends = server.commandCodes().count { it == Lab.NK_END_LIVE_VIEW }
                                check(ends == if (liveView == LiveViewCase.BAD_FRAME) 1 else 0) {
                                    "$liveView sent $ends EndLiveView commands"
                                }
                            } finally { camera.close() }
                            server.awaitFinished()
                        }
                    }
                    passed += "$liveView cannot persist pairing and respects LV cleanup ownership"
                }

                for (recovery in CleanupRecovery.entries) {
                    withFixture { fixture ->
                        fixture.pairingPrefs().edit().putString("initiator_id", SAVED_INITIATOR).commit()
                        val recoveryPlan = when (recovery) {
                            CleanupRecovery.NORMAL, CleanupRecovery.END_PINGS -> SessionPlan(rejectAlbumWhileLiveView = true)
                            CleanupRecovery.ALREADY_STOPPED -> SessionPlan(stoppedOnConnect = true)
                            CleanupRecovery.END_DENIED -> SessionPlan(liveView = LiveViewCase.END_DENIED)
                            CleanupRecovery.STILL_ACTIVE -> SessionPlan(liveView = LiveViewCase.END_STUCK)
                            CleanupRecovery.WRONG_CAMERA -> SessionPlan(guid = GUID_B, expectsEventConnection = false)
                            CleanupRecovery.PAIRING_ONLY -> SessionPlan(pairingOnlyDeviceInfo = true)
                            CleanupRecovery.ALBUM_DENIED -> SessionPlan(
                                deniedObjectInfoHandle = 0x00010001, objectSizeReply = ObjectSizeReply.DENIED,
                            )
                        }
                        val cleanupPlan = if (recovery == CleanupRecovery.END_PINGS) SessionPlan(
                            stalledOperation = Lab.NK_END_LIVE_VIEW, stalledReply = StalledReply.PINGS,
                        ) else SessionPlan(liveView = LiveViewCase.END_DENIED)
                        FakeStaServer(listOf(
                            SessionPlan(event = PairingEvent.FRESH_CHANGED), cleanupPlan, recoveryPlan,
                        )).use { server ->
                            val receipt = obtainConfirmation(fixture)
                            check(!receipt.remotePermissionVerified)
                            val cleanupStartedAt = System.nanoTime()
                            val verified = obtainCleanupConfirmation(fixture, receipt)
                            if (recovery == CleanupRecovery.END_PINGS) {
                                val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - cleanupStartedAt)
                                check(elapsedMs in 4_500..7_000) { "Cleanup PINGs stalled for ${elapsedMs}ms" }
                            }
                            val recoveryCommandStart = server.commandCodes().size
                            val restored = NikonCamera(fixture)
                            try {
                                val result = restored.connectSta(
                                    ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                                    pairingConfirmation = verified,
                                    // Even an accidentally enabled repair flag must not override a proven frame.
                                    allowPairing = recovery == CleanupRecovery.PAIRING_ONLY,
                                    allowInlinePairingRecovery = recovery == CleanupRecovery.PAIRING_ONLY,
                                )
                                if (recovery in listOf(CleanupRecovery.NORMAL, CleanupRecovery.END_PINGS, CleanupRecovery.ALREADY_STOPPED)) {
                                    result.getOrThrow()
                                    check(restored.staPairingConfirmed && restored.staAlbumAccessValidated)
                                    check(fixture.pairingPrefs().getBoolean(STA_PAIRING_VERIFIED_MARKER_PREFIX + GUID_A, false))
                                } else {
                                    check(result.isFailure) { "$recovery bypassed the final connection checks" }
                                    check(!restored.staPairingConfirmed && !restored.staAlbumAccessValidated)
                                    fixture.assertNoPairingMarker(GUID_A)
                                    fixture.assertNoPairingMarker(GUID_B)
                                    if (recovery == CleanupRecovery.WRONG_CAMERA) {
                                        check(result.exceptionOrNull() is UnexpectedStaResponderException)
                                    }
                                    if (recovery == CleanupRecovery.PAIRING_ONLY) {
                                        check(result.exceptionOrNull() is PairingNotConfirmedException)
                                    }
                                    if (recovery in listOf(CleanupRecovery.END_DENIED, CleanupRecovery.STILL_ACTIVE)) {
                                        check(result.exceptionOrNull() is StaPairingCleanupException) {
                                            "Unfinished recovery cleanup must remain distinct from failed pairing: ${result.exceptionOrNull()}"
                                        }
                                    }
                                }
                                val codes = server.commandCodes()
                                check(codes.count { it == PtpConstants.NK_PAIRING_QUERY } == 1)
                                check(codes.count { it == PtpConstants.NK_PAIRING_RESULT } == 1)
                                check(codes.count { it == Lab.NK_GET_LIVE_VIEW_IMG } == 1)
                                check(codes.count { it == Lab.NK_START_LIVE_VIEW } == 1)
                                val recoveryCodes = codes.drop(recoveryCommandStart)
                                val expectedEnds = if (recovery in listOf(CleanupRecovery.WRONG_CAMERA, CleanupRecovery.ALREADY_STOPPED)) 1 else 2
                                check(codes.count { it == Lab.NK_END_LIVE_VIEW } == expectedEnds) {
                                    "$recovery did not perform exactly the necessary cleanup"
                                }
                                if (recovery in listOf(CleanupRecovery.END_DENIED, CleanupRecovery.STILL_ACTIVE)) {
                                    check(PtpConstants.GET_STORAGE_IDS !in recoveryCodes) { "Unfinished cleanup proceeded to album access" }
                                }
                                if (recovery in listOf(CleanupRecovery.NORMAL, CleanupRecovery.END_PINGS)) {
                                    check(recoveryCodes.indexOf(Lab.NK_END_LIVE_VIEW) < recoveryCodes.indexOf(PtpConstants.GET_STORAGE_IDS))
                                }
                            } finally { restored.close() }
                            server.awaitFinished()
                            check(server.initiators().all { it == SAVED_INITIATOR })
                        }
                    }
                    passed += "$recovery cleanup recovery retains actual-frame proof without pairing again; final checks remain required"
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

                for (enhancedReply in EnhancedFrameReply.entries) {
                    withFixture { fixture ->
                        FakeStaServer(listOf(
                            SessionPlan(event = PairingEvent.FRESH_CHANGED),
                            SessionPlan(liveView = LiveViewCase.GATED_FRAME, enhancedFrameReply = enhancedReply),
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
                                    // The advertised enhanced operation is insufficient: even after
                                    // fallback, no trust may be saved until a standard JPEG arrives.
                                    server.awaitFrameRequest()
                                    check(!camera.staPairingConfirmed)
                                    fixture.assertNoPairingMarker(GUID_A)
                                    val frameRequests = server.commandCodes().filter {
                                        it == Lab.NK_GET_LIVE_VIEW_IMG_EX || it == Lab.NK_GET_LIVE_VIEW_IMG
                                    }
                                    val enhancedAttempts = if (enhancedReply == EnhancedFrameReply.UNSUPPORTED) 1 else 2
                                    check(frameRequests == List(enhancedAttempts) { Lab.NK_GET_LIVE_VIEW_IMG_EX } +
                                        Lab.NK_GET_LIVE_VIEW_IMG) {
                                        "Unexpected enhanced fallback order: $frameRequests"
                                    }
                                    server.releaseFrame()
                                    connection.await().getOrThrow()
                                    check(camera.staPairingConfirmed && camera.staAlbumAccessValidated)
                                    check(fixture.pairingPrefs().getBoolean(STA_PAIRING_VERIFIED_MARKER_PREFIX + GUID_A, false))
                                    check(server.commandCodes().count { it == Lab.NK_END_LIVE_VIEW } == 1)
                                }
                            } finally { camera.close() }
                            server.awaitFinished()
                        }
                    }
                    passed += "enhanced $enhancedReply falls back to standard JPEG before persisting pairing"
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
                                "Pairing-only reconnect without repair permission must fail even after Result ACK: ${result.exceptionOrNull()}"
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
                    FakeStaServer(listOf(SessionPlan(event = PairingEvent.TIMEOUT_CONNECTED, gatePairingResultAck = true))).use { server ->
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
                                server.releasePairingAck()
                                var cancelled = false
                                try { connection.await() } catch (_: CancellationException) { cancelled = true }
                                check(cancelled) { "Cancelled pairing returned a successful receipt" }
                            }
                            check(!camera.staPairingConfirmed && !camera.staAlbumAccessValidated)
                            fixture.assertNoPairingMarker(GUID_A)
                        } finally {
                            server.releasePairingAck()
                            camera.close()
                        }
                        server.awaitFinished()
                    }
                }
                passed += "cancellation rejects a late Result ACK without persisting trust"

                for (operation in listOf(PtpConstants.NK_PAIRING_QUERY, PtpConstants.NK_PAIRING_RESULT)) {
                    withFixture { fixture ->
                        FakeStaServer(listOf(SessionPlan(
                            event = PairingEvent.FRESH_CHANGED,
                            stalledOperation = operation,
                            stalledReply = StalledReply.PARTIAL_UNTIL_ABORT,
                        ))).use { server ->
                            val camera = NikonCamera(fixture)
                            try {
                                coroutineScope {
                                    val connection = async(Dispatchers.Default) {
                                        camera.connectSta(ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true)
                                    }
                                    server.awaitPartialResponse()
                                    val startedAt = System.nanoTime()
                                    connection.cancel()
                                    camera.abortStaConnectionAttempt()
                                    var cancelled = false
                                    try { connection.await() } catch (_: CancellationException) { cancelled = true }
                                    check(cancelled)
                                    check(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt) < 2_000) {
                                        "Cancelled half-response waited for the handshake timeout"
                                    }
                                }
                                check(!camera.staPairingConfirmed && !camera.staAlbumAccessValidated)
                                fixture.assertNoPairingMarker(GUID_A)
                                check(server.commandCodes().last() == operation)
                                check(PtpConstants.CLOSE_SESSION !in server.commandCodes()) {
                                    "Cancellation reused the partial command stream"
                                }
                            } finally { camera.close() }
                            server.awaitFinished()
                        }
                    }
                    passed += "cancelling 0x${operation.toString(16)} half-response aborts transport without further commands"
                }

                for (handleReply in listOf(HandleReply.SLOW_DATA, HandleReply.IDLE)) {
                    withFixture { fixture ->
                        fixture.pairingPrefs().edit()
                            .putString("initiator_id", SAVED_INITIATOR)
                            .putBoolean(STA_PAIRING_MARKER_PREFIX + GUID_A, true)
                            .putBoolean(STA_PAIRING_VERIFIED_MARKER_PREFIX + GUID_A, true)
                            .commit()
                        FakeStaServer(listOf(SessionPlan(handleReply = handleReply, liveView = LiveViewCase.UNSUPPORTED))).use { server ->
                            val camera = NikonCamera(fixture)
                            try {
                                val startedAt = System.nanoTime()
                                val result = camera.connectSta(ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true)
                                val elapsed = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt)
                                if (handleReply == HandleReply.SLOW_DATA) {
                                    result.getOrThrow()
                                    check(camera.staPairingConfirmed && camera.staAlbumAccessValidated)
                                    check(elapsed in 5_500..9_000) { "Slow handle data did not exercise the longer list budget: $elapsed ms" }
                                } else {
                                    check(result.exceptionOrNull() is SocketTimeoutException) { "Silent handles did not use the idle timeout: ${result.exceptionOrNull()}" }
                                    check(!camera.staAlbumAccessValidated)
                                    check(elapsed in 4_500..5_900) { "Silent list response waited $elapsed ms" }
                                    check(PtpConstants.CLOSE_SESSION !in server.commandCodes())
                                }
                                check(server.commandCodes().none { it in LIVE_VIEW_COMMANDS || it == PtpConstants.NK_PAIRING_QUERY || it == PtpConstants.NK_PAIRING_RESULT })
                                check(fixture.pairingPrefs().getBoolean(STA_PAIRING_VERIFIED_MARKER_PREFIX + GUID_A, false))
                                check(fixture.pairingPrefs().getString("initiator_id", null) == SAVED_INITIATOR)
                            } finally { camera.close() }
                            server.awaitFinished()
                        }
                    }
                    passed += "$handleReply existing-pairing handles preserve active data allowance and 5s idle timeout"
                }

                for (trusted in listOf(true, false)) {
                    withFixture { fixture ->
                        fixture.pairingPrefs().edit()
                            .putString("initiator_id", SAVED_INITIATOR)
                            .putBoolean(STA_PAIRING_MARKER_PREFIX + GUID_A, true)
                            .apply {
                                if (trusted) putBoolean(STA_PAIRING_VERIFIED_MARKER_PREFIX + GUID_A, true)
                            }.commit()
                        FakeStaServer(listOf(SessionPlan(
                            liveView = LiveViewCase.UNSUPPORTED,
                            stalledOperation = GET_STORAGE_INFO,
                            stalledReply = StalledReply.PINGS_THEN_RESPONSE,
                        ))).use { server ->
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
                                camera.withCameraTransaction(CameraRequestKind.INTERACTIVE, "CONNECTED_HEARTBEAT_FIXTURE") {
                                    val previousTimeout = camera.setCommandReadTimeout(500)
                                    try {
                                        val startedAt = System.nanoTime()
                                        camera.sendCmd(GET_STORAGE_INFO, 0x00010001)
                                        check(camera.recvRespWithPayload().first == Lab.OK)
                                        check(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt) >= 900) {
                                            "Connected-session fixture did not exceed its socket idle timeout"
                                        }
                                    } finally { camera.restoreCommandReadTimeout(previousTimeout) }
                                }
                            } finally { camera.close() }
                            server.awaitFinished()
                            check(server.initiators() == listOf(SAVED_INITIATOR))
                        }
                    }
                    passed += "${if (trusted) "v2" else "legacy"} saved pairing reuses identity; ordinary replies retain idle timeout semantics"
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

    /** Exercises the actual Debug recovery coordinator; only service-restart sleeps are skipped. */
    private suspend fun verifyProbeRecovery(passed: MutableList<String>) {
        val candidate = PtpIpCandidate(LOOPBACK, null)
        suspend fun validate(fixture: FixtureContext, waits: MutableList<Long>): Boolean =
            StaPairingPropertyProbe.validateWithRecovery(
                fixture, candidate, GUID_A, firstResultAcknowledgedMs = null,
                wait = { waits += it },
            )
        fun assertNoTrust(fixture: FixtureContext, server: FakeStaServer) {
            fixture.assertNoPairingMarker(GUID_A)
            fixture.assertNoPairingMarker(GUID_B)
            check(server.initiators().distinct().size == 1) { "Recovery changed the host identity" }
            check(PtpConstants.CLOSE_SESSION !in server.commandCodes()) {
                "The simplified probe sent an unnecessary CloseSession"
            }
        }

        for (stillPairingOnly in listOf(false, true)) {
            withFixture { fixture ->
                FakeStaServer(listOf(
                    // Real Z30 drops its network if Live View is requested while it advertises
                    // pairing-only operations. This peer forbids all monitor requests in that state.
                    SessionPlan(event = PairingEvent.TIMEOUT_CONNECTED, pairingOnlyDeviceInfo = true,
                        liveView = LiveViewCase.UNSUPPORTED),
                    SessionPlan(pairingOnlyDeviceInfo = stillPairingOnly,
                        liveView = if (stillPairingOnly) LiveViewCase.UNSUPPORTED else LiveViewCase.NORMAL),
                )).use { server ->
                    val waits = mutableListOf<Long>()
                    val selected = mutableListOf<String>()
                    val result = runCatching {
                        StaPairingPropertyProbe.validateWithRecovery(
                            fixture, candidate, guid = null, firstResultAcknowledgedMs = null,
                            onTargetSelected = { selected += it }, wait = { waits += it },
                        )
                    }
                    if (stillPairingOnly) {
                        check(result.exceptionOrNull() is PairingNotConfirmedException) {
                            "Still pairing-only after repair must stop: ${result.exceptionOrNull()}"
                        }
                    } else {
                        check(result.getOrThrow()) { "Pairing-only state did not use the one allowed repair" }
                    }
                    server.awaitFinished()
                    val codes = server.commandCodes()
                    check(codes.count { it == PtpConstants.NK_PAIRING_QUERY } == 1)
                    check(codes.count { it == PtpConstants.NK_PAIRING_RESULT } == 1)
                    check(codes.count { it == Lab.NK_START_LIVE_VIEW } == if (stillPairingOnly) 0 else 1)
                    if (!stillPairingOnly) {
                        check(codes.indexOf(Lab.NK_START_LIVE_VIEW) > codes.indexOf(PtpConstants.NK_PAIRING_RESULT)) {
                            "Live View was requested before completing the pairing exchange"
                        }
                        check(codes.count { it == Lab.NK_GET_LIVE_VIEW_IMG } == 1)
                    } else {
                        check(codes.none { it in LIVE_VIEW_COMMANDS })
                    }
                    check(selected == listOf(GUID_A)) { "The camera was not locked exactly once" }
                    check(server.initiators().size == 2)
                    check(waits.size == 1 && waits.single() in 0..6_600L)
                    assertNoTrust(fixture, server)
                }
            }
            passed += if (stillPairingOnly)
                "probe persistent pairing-only state stops after one inline repair without any monitor request"
            else
                "probe pairing-only state pairs in the open session before one valid monitor verification"
        }

        for (failure in listOf(LiveViewCase.START_DENIED, LiveViewCase.START_EOF, LiveViewCase.BAD_FRAME)) {
            withFixture { fixture ->
                FakeStaServer(listOf(
                    SessionPlan(liveView = failure),
                    SessionPlan(event = PairingEvent.TIMEOUT_CONNECTED),
                    SessionPlan(),
                )).use { server ->
                    val waits = mutableListOf<Long>()
                    val selected = mutableListOf<String>()
                    check(StaPairingPropertyProbe.validateWithRecovery(
                        fixture, candidate, guid = null, firstResultAcknowledgedMs = null,
                        onTargetSelected = { selected += it }, wait = { waits += it },
                    )) { "An unpaired frame failure was not repaired" }
                    check(selected == listOf(GUID_A)) { "The first camera was not locked exactly once" }
                    server.awaitFinished()
                    val codes = server.commandCodes()
                    check(codes.count { it == PtpConstants.NK_PAIRING_QUERY } == 1)
                    check(codes.count { it == PtpConstants.NK_PAIRING_RESULT } == 1)
                    check(codes.indexOf(Lab.NK_START_LIVE_VIEW) < codes.indexOf(PtpConstants.NK_PAIRING_QUERY)) {
                        "The simulated first attempt paired before requesting Live View"
                    }
                    check(codes.count { it == Lab.NK_START_LIVE_VIEW } == 2)
                    check(codes.count { it == Lab.NK_GET_LIVE_VIEW_IMG } >= 1)
                    check(server.initiators().size == 3)
                    check(waits.size == 2 && waits.all { it in 0..6_600L })
                    assertNoTrust(fixture, server)
                }
            }
            passed += "probe $failure before pairing automatically repairs once and obtains a valid frame"
        }

        withFixture { fixture ->
            FakeStaServer(listOf(
                SessionPlan(liveView = LiveViewCase.START_DENIED),
                SessionPlan(event = PairingEvent.TIMEOUT_CONNECTED),
                SessionPlan(liveView = LiveViewCase.START_DENIED),
            )).use { server ->
                val result = runCatching { validate(fixture, mutableListOf()) }
                check(result.exceptionOrNull() is PairingNotConfirmedException)
                server.awaitFinished()
                check(server.commandCodes().count { it == PtpConstants.NK_PAIRING_QUERY } == 1)
                check(server.commandCodes().count { it == PtpConstants.NK_PAIRING_RESULT } == 1)
                check(server.initiators().size == 3)
                assertNoTrust(fixture, server)
            }
        }
        passed += "probe second frame failure stops after exactly one repair without pairing trust"

        for (plan in listOf(
            SessionPlan(liveView = LiveViewCase.END_DENIED),
            SessionPlan(deviceInfoResponse = Lab.DEVICE_BUSY),
            SessionPlan(liveViewStatusResponse = Lab.ACCESS_DENIED),
        )) {
            withFixture { fixture ->
                FakeStaServer(listOf(plan)).use { server ->
                    val waits = mutableListOf<Long>()
                    val result = runCatching { validate(fixture, waits) }
                    check(result.isFailure)
                    if (plan.liveView == LiveViewCase.END_DENIED) {
                        check(result.exceptionOrNull() is StaPairingCleanupException)
                        check(Lab.NK_GET_LIVE_VIEW_IMG in server.commandCodes())
                    } else {
                        check(Lab.NK_START_LIVE_VIEW !in server.commandCodes())
                    }
                    server.awaitFinished()
                    check(waits.isEmpty())
                    check(server.commandCodes().none {
                        it == PtpConstants.NK_PAIRING_QUERY || it == PtpConstants.NK_PAIRING_RESULT
                    })
                    assertNoTrust(fixture, server)
                }
            }
            passed += "probe cleanup/read failure ${plan.liveView}/${plan.deviceInfoResponse}/${plan.liveViewStatusResponse} never pairs again"
        }

        withFixture { fixture ->
            FakeStaServer(listOf(
                SessionPlan(liveView = LiveViewCase.START_DENIED),
                SessionPlan(guid = GUID_B, expectsEventConnection = false),
            )).use { server ->
                val result = runCatching { validate(fixture, mutableListOf()) }
                check(result.exceptionOrNull() is UnexpectedStaResponderException)
                server.awaitFinished()
                check(server.commandCodes().none {
                    it == PtpConstants.NK_PAIRING_QUERY || it == PtpConstants.NK_PAIRING_RESULT
                })
                check(server.initiators().size == 2)
                assertNoTrust(fixture, server)
            }
        }
        passed += "probe recovery refuses a different camera before sending pairing commands"

        for (rejectQuery in listOf(true, false)) {
            withFixture { fixture ->
                FakeStaServer(listOf(
                    SessionPlan(liveView = LiveViewCase.START_DENIED),
                    SessionPlan(event = PairingEvent.TIMEOUT_CONNECTED,
                        pairingQueryResponse = if (rejectQuery) Lab.ACCESS_DENIED else Lab.OK,
                        pairingResultResponse = if (rejectQuery) Lab.OK else Lab.ACCESS_DENIED),
                )).use { server ->
                    check(runCatching { validate(fixture, mutableListOf()) }.isFailure)
                    server.awaitFinished()
                    check(server.commandCodes().count { it == PtpConstants.NK_PAIRING_QUERY } == 1)
                    check(server.commandCodes().count { it == PtpConstants.NK_PAIRING_RESULT } == if (rejectQuery) 0 else 1)
                    check(server.initiators().size == 2)
                    assertNoTrust(fixture, server)
                }
            }
            passed += "probe rejected ${if (rejectQuery) "Query" else "Result"} stops without another repair"
        }

        withFixture { fixture ->
            FakeStaServer(listOf(SessionPlan(liveView = LiveViewCase.START_DENIED))).use { server ->
                val result = runCatching {
                    StaPairingPropertyProbe.validateWithRecovery(
                        fixture, candidate, GUID_A, firstResultAcknowledgedMs = null,
                        wait = { throw CancellationException("controlled cancellation before repair") },
                    )
                }
                check(result.exceptionOrNull() is CancellationException)
                server.awaitFinished()
                check(server.commandCodes().none {
                    it == PtpConstants.NK_PAIRING_QUERY || it == PtpConstants.NK_PAIRING_RESULT
                })
                assertNoTrust(fixture, server)
            }
        }
        passed += "probe cancellation during repair wait cannot send another pairing request"

        withFixture { fixture ->
            FakeStaServer(listOf(SessionPlan())).use { server ->
                val waits = mutableListOf<Long>()
                check(!validate(fixture, waits))
                server.awaitFinished()
                check(waits.isEmpty())
                check(server.commandCodes().none {
                    it == PtpConstants.NK_PAIRING_QUERY || it == PtpConstants.NK_PAIRING_RESULT
                })
                assertNoTrust(fixture, server)
            }
        }
        passed += "probe successful first validation needs no repair, delay or extra pairing"
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

    private suspend fun obtainCleanupConfirmation(
        fixture: FixtureContext,
        confirmation: StaPairingConfirmation,
    ): StaPairingConfirmation {
        val camera = NikonCamera(fixture)
        return try {
            val result = camera.connectSta(
                ip = LOOPBACK, forceProfilePairing = true, exploreAlbumAccess = true,
                pairingConfirmation = confirmation,
            )
            val cleanup = result.exceptionOrNull() as? StaPairingCleanupException
                ?: error("Expected verified-frame cleanup failure: ${result.exceptionOrNull()}\n${camera.staDiagnosticReport}")
            check(!camera.staPairingConfirmed && !camera.staAlbumAccessValidated)
            fixture.assertNoPairingMarker(GUID_A)
            cleanup.confirmation.also {
                check(it.responderGuid == GUID_A && it.remotePermissionVerified)
            }
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
        TIMEOUT_CONNECTED, FRESH_CHANGED,
    }
    private enum class LiveViewCase {
        NORMAL, START_EOF, FRAME_EOF, START_DENIED, BAD_FRAME, END_DENIED,
        ALREADY_ACTIVE, BUSY_THEN_READY, GATED_FRAME, UNSUPPORTED, END_STUCK,
    }
    private enum class CloseReply { NORMAL, SILENT, PARTIAL_PACKET }
    private enum class ObjectSizeReply { VALID, DENIED, SHORT, ZERO }
    private enum class EnhancedFrameReply { UNSUPPORTED, INVALID_JPEG }
    private enum class StalledReply { PINGS, TRICKLED_PACKET, PINGS_THEN_RESPONSE, PARTIAL_UNTIL_ABORT, EOF }
    private enum class HandleReply { NORMAL, SLOW_DATA, IDLE }
    private enum class CleanupRecovery { NORMAL, END_PINGS, WRONG_CAMERA, PAIRING_ONLY, ALBUM_DENIED, ALREADY_STOPPED, END_DENIED, STILL_ACTIVE }
    private data class SessionPlan(
        val guid: String = GUID_A,
        val event: PairingEvent? = null,
        val expectsEventConnection: Boolean = true,
        val pairingOnlyDeviceInfo: Boolean = false,
        val deviceInfoResponse: Int = PtpConstants.RESPONSE_OK,
        val pairingQueryResponse: Int = PtpConstants.RESPONSE_OK,
        val pairingResultResponse: Int = PtpConstants.RESPONSE_OK,
        val gatePairingResultAck: Boolean = false,
        val liveViewStatusResponse: Int = PtpConstants.RESPONSE_OK,
        val liveView: LiveViewCase = LiveViewCase.NORMAL,
        val objectHandles: List<Int> = listOf(0x00010001),
        val deniedObjectInfoHandle: Int? = null,
        val closeReply: CloseReply = CloseReply.NORMAL,
        val objectSizeReply: ObjectSizeReply = ObjectSizeReply.VALID,
        val enhancedFrameReply: EnhancedFrameReply? = null,
        val stalledOperation: Int? = null,
        val stalledReply: StalledReply? = null,
        val handleReply: HandleReply = HandleReply.NORMAL,
        val rejectAlbumWhileLiveView: Boolean = false,
        val stoppedOnConnect: Boolean = false,
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
        private val pairingAckAllowed = CountDownLatch(1)
        private val frameRequested = CountDownLatch(1)
        private val frameAllowed = CountDownLatch(1)
        private val liveViewEnded = CountDownLatch(1)
        private val partialResponseSent = CountDownLatch(1)
        // Camera state survives a PTP session: a rejected EndLiveView must not disappear on reconnect.
        @Volatile private var liveViewActive = false
        @Volatile private var stopping = false
        private val worker = thread(name = "sta-pairing-fixture", isDaemon = true) {
            try { plans.forEach(::serveSession) }
            catch (error: Throwable) { if (!stopping) failure.set(error) }
        }

        fun commandCodes(): List<Int> = synchronized(commands) { commands.toList() }
        fun initiators(): List<String> = synchronized(hosts) { hosts.toList() }
        fun awaitPartialResponse() { check(partialResponseSent.await(8, TimeUnit.SECONDS)) { "Partial response was never sent" } }
        fun awaitPairingResult() { check(resultSent.await(8, TimeUnit.SECONDS)) { "Pairing Result was never sent" } }
        fun releasePairingAck() { pairingAckAllowed.countDown() }
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
            pairingAckAllowed.countDown()
            frameAllowed.countDown()
            listener.close()
            synchronized(sockets) { sockets.forEach { runCatching { it.close() } } }
            worker.join(3_000)
        }

        private fun accept(): Socket = listener.accept().apply {
            tcpNoDelay = true
            // Keep the synthetic peer alive through the bounded command/read tests; only the
            // client decides its timeout, not an artificially early server-side disconnect.
            soTimeout = 45_000
            sockets += this
        }

        private fun serveSession(plan: SessionPlan) {
            if (plan.liveView == LiveViewCase.ALREADY_ACTIVE) liveViewActive = true
            if (plan.stoppedOnConnect) liveViewActive = false
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
                if (code == plan.stalledOperation) {
                    if (plan.stalledReply == StalledReply.PINGS_THEN_RESPONSE) {
                        stallResponse(input, output, transaction, plan.stalledReply)
                        continue
                    }
                    try {
                        stallResponse(input, output, transaction, checkNotNull(plan.stalledReply))
                    } finally {
                        events.close()
                        command.close()
                    }
                    return
                }
                when (code) {
                    PtpConstants.OPEN_SESSION, 0x941C -> output.response(transaction)
                    PtpConstants.CLOSE_SESSION -> when (plan.closeReply) {
                        CloseReply.NORMAL -> output.response(transaction)
                        CloseReply.SILENT -> Unit
                        CloseReply.PARTIAL_PACKET -> {
                            // A complete header with a partial response body must time out;
                            // a second CloseSession must not reuse this unaligned reader.
                            output.write(bytes { u32(14); u32(PtpConstants.CMD_RESPONSE); u16(Lab.OK) })
                            output.flush()
                        }
                    }
                    PtpConstants.GET_STORAGE_IDS -> {
                        check(!plan.rejectAlbumWhileLiveView || !liveViewActive) {
                            "Album access was attempted before finishing the previous session's Live View cleanup"
                        }
                        output.response(transaction, bytes { u32(1); u32(0x00010001) })
                    }
                    PtpConstants.GET_DEVICE_INFO -> output.response(
                        transaction,
                        deviceInfo(plan.pairingOnlyDeviceInfo, plan.liveView != LiveViewCase.UNSUPPORTED,
                            plan.enhancedFrameReply != null).takeIf { plan.deviceInfoResponse == PtpConstants.RESPONSE_OK },
                        plan.deviceInfoResponse,
                    )
                    PtpConstants.GET_OBJECT_HANDLES -> {
                        val data = bytes { u32(plan.objectHandles.size); plan.objectHandles.forEach(::u32) }
                        when (plan.handleReply) {
                            HandleReply.NORMAL -> output.response(transaction, data)
                            HandleReply.SLOW_DATA -> {
                                output.packet(PtpConstants.START_DATA_PACKET, bytes { u32(transaction); u32(data.size); u32(0) })
                                data.forEachIndexed { index, byte ->
                                    Thread.sleep(750)
                                    val packetType = if (index == data.lastIndex) PtpConstants.END_DATA_PACKET else PtpConstants.DATA_PACKET
                                    output.packet(packetType, bytes { u32(transaction); raw(byteArrayOf(byte)) })
                                }
                                output.response(transaction)
                            }
                            HandleReply.IDLE -> {
                                // A larger total list budget must not turn a silent 5s socket into a 30s wait.
                                Thread.sleep(6_000)
                                try { output.response(transaction, data) } catch (_: SocketException) { }
                                events.close()
                                command.close()
                                return
                            }
                        }
                    }
                    // The production bounded access probe checks response success and ObjectInfo size.
                    PtpConstants.GET_OBJECT_INFO -> {
                        check(request.payload.size >= 14)
                        val denied = request.payload.i32(10) == plan.deniedObjectInfoHandle
                        output.response(transaction, ByteArray(64).takeUnless { denied },
                            if (denied) Lab.ACCESS_DENIED else Lab.OK)
                    }
                    PtpConstants.NK_GET_OBJECT_SIZE -> when (plan.objectSizeReply) {
                        ObjectSizeReply.VALID -> output.response(transaction, bytes { u32(65_536); u32(0) })
                        ObjectSizeReply.DENIED -> output.response(transaction, responseCode = Lab.ACCESS_DENIED)
                        ObjectSizeReply.SHORT -> output.response(transaction, bytes { u32(65_536) })
                        ObjectSizeReply.ZERO -> output.response(transaction, ByteArray(8))
                    }
                    PtpConstants.NK_GET_PARTIAL_OBJECT_EX -> {
                        check(plan.objectSizeReply == ObjectSizeReply.VALID) {
                            "Partial object read followed an invalid size"
                        }
                        output.response(transaction,
                            byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE1.toByte()))
                    }
                    0x9435 -> {
                        check(plan.objectSizeReply != ObjectSizeReply.VALID)
                        check(request.payload.size >= 14 && request.payload.i32(10) == 1)
                        output.response(transaction, responseCode = Lab.ACCESS_DENIED)
                    }
                    Lab.GET_DEVICE_PROP_VALUE -> {
                        check(request.payload.size >= 14 && request.payload.i32(10) == Lab.PROP_NK_LV_STATUS)
                        check(plan.liveView != LiveViewCase.UNSUPPORTED) { "Saved pairing read LV status" }
                        output.response(transaction,
                            byteArrayOf(if (liveViewActive) 1 else 0).takeIf { plan.liveViewStatusResponse == Lab.OK },
                            plan.liveViewStatusResponse)
                    }
                    Lab.NK_START_LIVE_VIEW -> {
                        check(plan.liveView != LiveViewCase.UNSUPPORTED)
                        check(plan.liveView != LiveViewCase.ALREADY_ACTIVE) { "Restarted an existing monitor" }
                        if (plan.liveView == LiveViewCase.START_EOF) {
                            events.close()
                            command.close()
                            return
                        }
                        if (plan.liveView != LiveViewCase.START_DENIED) liveViewActive = true
                        output.response(transaction, responseCode = if (plan.liveView == LiveViewCase.START_DENIED) Lab.ACCESS_DENIED else Lab.OK)
                    }
                    Lab.NK_DEVICE_READY -> {
                        check(plan.liveView != LiveViewCase.UNSUPPORTED)
                        output.response(transaction, responseCode =
                            if (plan.liveView == LiveViewCase.BUSY_THEN_READY && readyCalls++ == 0) Lab.DEVICE_BUSY else Lab.OK)
                    }
                    Lab.NK_GET_LIVE_VIEW_IMG_EX -> when (checkNotNull(plan.enhancedFrameReply)) {
                        EnhancedFrameReply.UNSUPPORTED -> output.response(transaction, responseCode = PtpConstants.OPERATION_NOT_SUPPORTED)
                        EnhancedFrameReply.INVALID_JPEG -> output.response(transaction, byteArrayOf(1, 2, 3))
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
                        if (plan.liveView !in listOf(LiveViewCase.END_DENIED, LiveViewCase.END_STUCK)) liveViewActive = false
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
                        output.response(transaction,
                            bytes { u32(0) }.takeIf { plan.pairingQueryResponse == Lab.OK },
                            plan.pairingQueryResponse)
                    }
                    PtpConstants.NK_PAIRING_RESULT -> {
                        check(request.payload.size >= 14 && request.payload.i32(10) == PtpConstants.RESPONSE_OK)
                        resultSent.countDown()
                        if (plan.gatePairingResultAck) {
                            check(pairingAckAllowed.await(8, TimeUnit.SECONDS)) { "Late Result ACK was not released" }
                        }
                        output.response(transaction, responseCode = plan.pairingResultResponse)
                        if (plan.pairingResultResponse != Lab.OK) continue
                        try {
                            when (checkNotNull(plan.event)) {
                                PairingEvent.FRESH_CHANGED -> eventOutput.packet(PtpConstants.EVENT,
                                    event(PtpConstants.EVENT_DEVICE_INFO_CHANGED, transaction))
                                PairingEvent.UNRELATED_THEN_EOF -> eventOutput.packet(PtpConstants.EVENT,
                                    event(0x4002, transaction))
                                PairingEvent.SHORT_CHANGED_THEN_EOF -> eventOutput.packet(PtpConstants.EVENT,
                                    bytes { u16(PtpConstants.EVENT_DEVICE_INFO_CHANGED) })
                                else -> Unit
                            }
                        } catch (_: SocketException) {
                            // Acknowledged pairing may close the transport before optional events.
                        }
                        if (plan.event !in setOf(PairingEvent.FRESH_CHANGED,
                                PairingEvent.TIMEOUT_CONNECTED)) events.close()
                    }
                    else -> error("Unexpected STA handshake command 0x${code.toString(16)}")
                }
            }
            events.close()
            command.close()
        }

        private fun stallResponse(
            input: InputStream,
            output: OutputStream,
            transaction: Int,
            mode: StalledReply,
        ) {
            try {
                when (mode) {
                    StalledReply.EOF -> Unit
                    StalledReply.PINGS -> {
                        // Idle traffic arrives well inside SO_TIMEOUT_MS. It must not renew
                        // the response deadline; without it this fixture stops after 9 seconds.
                        val stopAt = System.nanoTime() + TimeUnit.SECONDS.toNanos(9)
                        while (System.nanoTime() < stopAt) {
                            output.packet(PtpConstants.PING)
                            check(readPacket(input).type == PtpConstants.PONG)
                            Thread.sleep(200)
                        }
                    }
                    StalledReply.TRICKLED_PACKET -> {
                        // Even one response can keep a plain socket timeout alive indefinitely.
                        // Header plus body takes 6.5 seconds, beyond the 5-second response budget.
                        val packet = bytes {
                            u32(14); u32(PtpConstants.CMD_RESPONSE); u16(Lab.OK); u32(transaction)
                        }
                        packet.forEachIndexed { index, byte ->
                            if (index > 0) Thread.sleep(500)
                            output.write(byte.toInt() and 255)
                            output.flush()
                        }
                    }
                    StalledReply.PARTIAL_UNTIL_ABORT -> {
                        output.write(bytes { u32(14); u32(PtpConstants.CMD_RESPONSE); u16(Lab.OK) })
                        output.flush()
                        partialResponseSent.countDown()
                        check(input.read() == -1) { "Cancellation sent another command on a partial response" }
                    }
                    StalledReply.PINGS_THEN_RESPONSE -> {
                        repeat(20) {
                            output.packet(PtpConstants.PING)
                            check(readPacket(input).type == PtpConstants.PONG)
                            Thread.sleep(50)
                        }
                        output.response(transaction)
                    }
                }
            } catch (_: EOFException) {
                // The deadline closes the command channel even though traffic kept arriving.
            } catch (_: SocketException) {
                // A fragmented write can observe the deadline abort as a reset/broken pipe.
            }
        }
    }

    private data class Packet(val type: Int, val payload: ByteArray)
    private companion object {
        const val LOOPBACK = "127.0.0.1"
        const val GUID_A = "00112233445566778899aabbccddeeff"
        const val GUID_B = "102132435465768798a9bacbdcedfe0f"
        const val SAVED_INITIATOR = "1234567890abcdef"
        const val GET_STORAGE_INFO = 0x1005 // Post-handshake probe; unused by the pairing sequence.
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
        fun deviceInfo(pairingOnly: Boolean, liveViewSupported: Boolean, enhancedFrameSupported: Boolean = false) = bytes {
            u16(100); u32(10); u16(100); ptpString(""); u16(0)
            // Nikon's paired transfer profile may keep all five pairing codes plus GetVendorCodes;
            // it must not be misclassified as a new pairing merely because those codes remain.
            u16Array(listOf(PtpConstants.GET_DEVICE_INFO, PtpConstants.OPEN_SESSION, PtpConstants.CLOSE_SESSION,
                PtpConstants.NK_PAIRING_QUERY, PtpConstants.NK_PAIRING_RESULT) +
                if (pairingOnly) emptyList() else buildList {
                    add(0x9439)
                    if (liveViewSupported) addAll(LIVE_VIEW_COMMANDS)
                    if (enhancedFrameSupported) add(Lab.NK_GET_LIVE_VIEW_IMG_EX)
                })
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
