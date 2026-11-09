package com.ztransfer.diagnostics

import android.content.Context
import android.os.Build
import android.os.SystemClock
import com.ztransfer.BuildConfig
import com.ztransfer.protocol.Lab
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.protocol.PairingNotConfirmedException
import com.ztransfer.protocol.PtpConstants
import com.ztransfer.protocol.PtpIpCandidate
import com.ztransfer.protocol.PtpIpDiscovery
import com.ztransfer.protocol.cacheStaProbeDeviceInfo
import com.ztransfer.protocol.connectStaProbe
import com.ztransfer.protocol.isStaPairingOnlyOperationSet
import com.ztransfer.protocol.prepareStaProbeAlbumSession
import com.ztransfer.protocol.verifyStaPairingLiveView
import java.io.File
import java.io.IOException
import java.time.Instant
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

/** Explicit, one-shot Debug experiment. It never activates an album or persists pairing trust. */
internal object StaPairingPropertyProbe {
    data class State(
        val running: Boolean = false,
        val phase: String = "尚未开始",
        val delivery: String = "",
        val hasReport: Boolean = false,
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutableState = MutableStateFlow(State())
    val state: StateFlow<State> = mutableState.asStateFlow()
    private val lock = Any()
    private var runJob: Job? = null
    @Volatile private var activeCamera: NikonCamera? = null
    private var report = StringBuilder()
    private var startedMs = 0L
    private const val REPORT_FILE = "sta-pairing-property-probe-latest.txt"
    private const val MAX_REPORT_CHARACTERS = 192 * 1024

    fun start(
        context: Context,
        simulateUnpaired: Boolean = false,
        prepare: suspend () -> Unit,
        finished: () -> Unit = {},
    ) {
        val appContext = context.applicationContext
        synchronized(lock) {
            if (runJob?.isActive == true) return
            startedMs = SystemClock.elapsedRealtime()
            report = StringBuilder()
            mutableState.value = State(running = true, phase = "准备首次配对探测", hasReport = true)
            runJob = scope.launch(start = CoroutineStart.LAZY) {
                var outcome = "failed"
                try {
                    note("STA simplified pairing flow probe v5 ${Instant.now()} app=${BuildConfig.VERSION_NAME}(${BuildConfig.VERSION_CODE}) Android=${Build.VERSION.SDK_INT}")
                    note("simulateUnpaired=$simulateUnpaired; explicit pairing-only state repairs on the current connection BEFORE any monitor request. Otherwise a failed remote request permits one same-camera recovery. Never synthesize a failure.")
                    note("No pre-result event drain, no 0x4008 gate or candidate probes. Production keeps the pairing receipt and retries for 60s after ACK. This isolated Debug experiment still uses its own 6600ms interval, not the normal STA entry.")
                    note("This experiment never activates the album or persists pairing trust. A valid frame proves current remote access, not persistence across camera restart. No image content is retained.")
                    withContext(Dispatchers.Main.immediate) { prepare() }
                    withTimeout(120_000L) { runExperiment(appContext, simulateUnpaired) }
                    outcome = "complete"
                    mutableState.update { it.copy(phase = "探测完成") }
                } catch (cancelled: CancellationException) {
                    outcome = if (cancelled is kotlinx.coroutines.TimeoutCancellationException) "overall-timeout" else "cancelled"
                    note("RESULT $outcome")
                    mutableState.update { it.copy(phase = if (outcome == "cancelled") "探测已停止" else "探测超时") }
                } catch (error: Exception) {
                    note("ERROR ${describe(error)}")
                    mutableState.update { it.copy(phase = "探测结束，已记录失败") }
                } finally {
                    // A dialog/navigation change cannot lose the report or stop its delivery.
                    withContext(NonCancellable) {
                        activeCamera?.abortStaConnectionAttempt()
                        activeCamera = null
                        note("PROBE_FINISHED outcome=$outcome; no pairing trust saved")
                        withContext(Dispatchers.Main.immediate) {
                            runCatching { finished() }.onFailure { note("FINISH callback failed ${it.javaClass.simpleName}") }
                        }
                        val payload = snapshot(appContext)
                        persist(appContext, payload)
                        mutableState.update { it.copy(delivery = "正在发送 QQ 日志") }
                        try {
                            StaProbeQqSender.send(appContext, payload)
                            note("DELIVERY QQ accepted TXT")
                            mutableState.update { it.copy(delivery = "日志已发到 QQ") }
                        } catch (error: Exception) {
                            // Sender owns credential sanitization; keep UI/report generic as a second barrier.
                            note("DELIVERY failed type=${error.javaClass.simpleName}; manual sharing available")
                            mutableState.update { it.copy(delivery = "自动发送失败，可手动分享") }
                        }
                        persist(appContext, snapshot(appContext))
                        mutableState.update { it.copy(running = false, hasReport = true) }
                    }
                }
            }.also { it.start() }
        }
    }

    fun cancel() {
        synchronized(lock) { runJob?.cancel() }
        val camera = activeCamera ?: return
        // Socket reads are blocking; cancellation alone does not wake them promptly.
        scope.launch { camera.abortStaConnectionAttempt() }
    }

    fun snapshot(context: Context): String {
        synchronized(lock) { if (report.isNotEmpty()) return report.toString() }
        val restored = runCatching { File(context.filesDir, REPORT_FILE).takeIf { it.isFile }?.readText().orEmpty() }
            .getOrDefault("")
        if (restored.isNotBlank()) mutableState.update { it.copy(hasReport = true) }
        return restored
    }

    private suspend fun runExperiment(context: Context, simulateUnpaired: Boolean) {
        var selected: PtpIpCandidate? = null
        var guid: String? = null
        var resultAcknowledgedMs: Long? = null
        var initialResult: Result<Unit>? = null
        var repaired = false

        phase(context, "查找相机", "DISCOVERY")
        PtpIpDiscovery(context).discover(
            lastIp = null,
            onProgress = { mutableState.update { it.copy(phase = "查找相机") } },
            tryCandidate = { candidate ->
                val result = if (simulateUnpaired) {
                    // Keep the first connection: an unpaired Z30 may close its network if we
                    // disconnect or attempt StartLiveView before finishing its pairing wizard.
                    note("SIMULATION initial Query/Result deliberately omitted; verifying recovery from the camera's actual state")
                    try {
                        repaired = validateWithRecovery(context, candidate, null, null,
                            onTargetSelected = { cameraGuid ->
                                selected = candidate
                                guid = cameraGuid
                                note("TARGET guid=$guid localRoute=${candidate.localAddress?.hostAddress ?: "default"}")
                            })
                        Result.success(Unit)
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (error: Exception) {
                        Result.failure(error)
                    }
                } else session(context, candidate, null, "INITIAL") { camera ->
                    initialize(camera, "INITIAL")
                    selected = candidate
                    guid = checkNotNull(camera.staResponderGuid)
                    note("TARGET guid=$guid localRoute=${candidate.localAddress?.hostAddress ?: "default"}")
                    resultAcknowledgedMs = exchangePairing(context, camera, "PAIRING_EXCHANGE")
                }
                if (selected != null) {
                    initialResult = result
                    true // Once selected, discovery cannot switch bodies or repeat the exchange.
                } else {
                    note("DISCOVERY candidate rejected ${result.exceptionOrNull()?.let(::describe).orEmpty()}")
                    false
                }
            },
        )
        val candidate = selected ?: throw IOException("未找到可探测的尼康相机")
        initialResult?.getOrThrow() ?: throw IOException("配对会话未完成")
        val confirmedGuid = checkNotNull(guid)
        check(simulateUnpaired || resultAcknowledgedMs != null) { "未收到配对请求确认" }
        if (!simulateUnpaired) {
            repaired = validateWithRecovery(context, candidate, confirmedGuid, resultAcknowledgedMs)
        }
        if (simulateUnpaired && !repaired) {
            throw IOException("未出现配对受限或监看失败，本次没有验证补救路径")
        }
        note("END simplified flow validated: recoveryUsed=$repaired; same-camera album access and actual Live View frame verified, cleanup complete. No app trust saved, no album activation.")
    }

    private suspend fun exchangePairing(context: Context, camera: NikonCamera, stage: String): Long {
        phase(context, "执行配对交换", stage)
        requireOk(command(camera, stage, PtpConstants.NK_PAIRING_QUERY), "Pairing Query")
        requireOk(command(camera, stage, PtpConstants.NK_PAIRING_RESULT, PtpConstants.RESPONSE_OK), "Pairing Result")
        val acknowledgedAt = SystemClock.elapsedRealtime()
        note("PAIRING_RESULT_ACK stage=$stage; no event wait/drain or further request on this session; release transport now.")
        return acknowledgedAt
    }

    private suspend fun waitAfterAck(context: Context, acknowledgedAt: Long, wait: suspend (Long) -> Unit) {
        phase(context, "等待相机恢复", "WAIT_AFTER_ACK")
        val remaining = (6_600L - (SystemClock.elapsedRealtime() - acknowledgedAt)).coerceAtLeast(0L)
        note("WAIT_AFTER_ACK plannedMs=$remaining targetSinceAckMs=6600; this is the retained test interval, not a proven minimum")
        wait(remaining)
        currentCoroutineContext().ensureActive()
        note("WAIT_AFTER_ACK actualSinceAckMs=${SystemClock.elapsedRealtime() - acknowledgedAt}")
    }

    /** Shared by the phone probe and socket tests; the latter replace only the restart wait. */
    internal suspend fun validateWithRecovery(
        context: Context,
        candidate: PtpIpCandidate,
        guid: String?,
        firstResultAcknowledgedMs: Long?,
        onTargetSelected: (String) -> Unit = {},
        wait: suspend (Long) -> Unit = { delay(it) },
    ): Boolean {
        var targetGuid = guid
        firstResultAcknowledgedMs?.let { waitAfterAck(context, it, wait) }
        for (attempt in 1..2) {
            var frameUnconfirmed = false
            var inlineRecoveryAcknowledgedAt: Long? = null
            phase(context, "重新连接相机", "RECONNECT attempt=$attempt")
            val validation = session(context, candidate, targetGuid, "VALIDATE_$attempt") { camera ->
                phase(context, "检查相册访问", "ALBUM_VALIDATION attempt=$attempt")
                val albumStarted = SystemClock.elapsedRealtime()
                var pairingOnly = false
                try {
                    camera.prepareStaProbeAlbumSession()
                } catch (error: PairingNotConfirmedException) {
                    // This is a fresh camera instance: the cached DeviceInfo belongs to THIS
                    // preparation, never an earlier successful read. These five operations are
                    // explicit negative evidence; a full capability list is still NOT proof.
                    if (!isStaPairingOnlyOperationSet(camera.cachedDeviceInfo?.operations.orEmpty())) throw error
                    pairingOnly = true
                    note("ALBUM_VALIDATION pairing-only; do not start Live View on this unpaired session")
                }
                note("ALBUM_VALIDATION validated=${camera.staAlbumAccessValidated} elapsedMs=${SystemClock.elapsedRealtime() - albumStarted}")
                if (targetGuid == null) {
                    targetGuid = checkNotNull(camera.staResponderGuid)
                    onTargetSelected(checkNotNull(targetGuid))
                }
                if (pairingOnly) {
                    if (attempt == 2) throw PairingNotConfirmedException()
                    note("RECOVERY_TRIGGER explicit-pairing-only; reuse current connection, no monitor request or pre-pairing disconnect")
                    inlineRecoveryAcknowledgedAt = exchangePairing(context, camera, "RECOVERY_PAIRING_INLINE")
                    return@session
                }

                phase(context, "验证监看权限", "FRAME_VALIDATION attempt=$attempt")
                val frameStarted = SystemClock.elapsedRealtime()
                var frameSeen = false
                var remoteRequested = false
                try {
                    camera.verifyStaPairingLiveView { line ->
                        if (line.startsWith("pairing live-view request=")) remoteRequested = true
                        if (line == "pairing live-view=VALID_FRAME") {
                            frameSeen = true
                            phase(context, "结束本次监看", "LIVE_VIEW_CLEANUP")
                        }
                        note("FRAME_VALIDATION $line")
                    }
                } catch (error: PairingNotConfirmedException) {
                    // No repair for initialization/status reads, cancellation, or cleanup after
                    // a valid frame. StartLV EOF is a real observed unpaired Z30 response.
                    frameUnconfirmed = remoteRequested && !frameSeen
                    throw error
                }
                check(frameSeen) { "STA valid frame was not observed" }
                note("FRAME_VALIDATION success cleanup=complete elapsedMs=${SystemClock.elapsedRealtime() - frameStarted}")
                check(camera.staAlbumAccessValidated) { "STA album access not validated" }
            }
            currentCoroutineContext().ensureActive()
            inlineRecoveryAcknowledgedAt?.let {
                validation.getOrThrow()
                waitAfterAck(context, it, wait)
            }
            if (inlineRecoveryAcknowledgedAt != null) continue
            if (validation.isSuccess) return attempt == 2
            if (!frameUnconfirmed || attempt == 2) {
                note("RECOVERY stopped attempt=$attempt frameUnconfirmed=$frameUnconfirmed; no further pairing")
                validation.getOrThrow()
            }

            note("RECOVERY_TRIGGER monitor-unconfirmed; one same-camera pairing exchange allowed")
            phase(context, "准备重新配对", "RECOVERY_WAIT plannedMs=6600")
            // Preserve the proven failure-recovery interval. Successful runs do not pay it.
            wait(6_600L)
            currentCoroutineContext().ensureActive()
            var recoveryAcknowledgedAt: Long? = null
            session(context, candidate, checkNotNull(targetGuid), "RECOVERY_PAIRING") { camera ->
                initialize(camera, "RECOVERY_PAIRING")
                recoveryAcknowledgedAt = exchangePairing(context, camera, "RECOVERY_PAIRING")
            }.getOrThrow()
            waitAfterAck(context, checkNotNull(recoveryAcknowledgedAt), wait)
        }
        error("STA validation exhausted without a result")
    }

    private suspend fun session(
        context: Context,
        candidate: PtpIpCandidate,
        guid: String?,
        label: String,
        body: suspend (NikonCamera) -> Unit,
    ): Result<Unit> {
        currentCoroutineContext().ensureActive()
        val camera = NikonCamera(context)
        activeCamera = camera
        val begin = SystemClock.elapsedRealtime()
        try {
            note("SESSION $label begin expectedGuid=${guid ?: "first-camera"}")
            return camera.connectStaProbe(
                ip = candidate.ip,
                localAddress = candidate.localAddress,
                expectedResponderGuid = guid,
                body = body,
            ).also { result ->
                note("SESSION $label result=${if (result.isSuccess) "complete" else describe(checkNotNull(result.exceptionOrNull()))} elapsedMs=${SystemClock.elapsedRealtime() - begin}")
                note("SESSION $label protocol trace:\n${camera.staDiagnosticReport}")
            }
        } finally {
            // Closing directly after Result ACK is the new timing under test. Never issue a
            // competing CloseSession while the body may already be switching its service.
            note("SESSION $label transport close begin; no CloseSession sent")
            withContext(NonCancellable) { camera.abortStaConnectionAttempt() }
            if (activeCamera === camera) activeCamera = null
            note("SESSION $label transport closed; elapsedMs=${SystemClock.elapsedRealtime() - begin}")
            persist(context, snapshot(context))
        }
    }

    private suspend fun initialize(camera: NikonCamera, stage: String) {
        requireOk(command(camera, stage, 0x941C), "Nikon compatibility init")
        readDeviceInfo(camera, stage)
    }

    private suspend fun readDeviceInfo(camera: NikonCamera, stage: String) {
        val (rc, data) = command(camera, stage, PtpConstants.GET_DEVICE_INFO)
        if (rc == Lab.OK && data != null) {
            runCatching { camera.cacheStaProbeDeviceInfo(data) }.onSuccess { info ->
                note("$stage model=${info.model} firmware=${info.deviceVersion} operations=${info.operations.size} supportsLV=${Lab.NK_START_LIVE_VIEW in info.operations} supportsEnhancedFrame=${Lab.NK_GET_LIVE_VIEW_IMG_EX in info.operations}")
            }.onFailure { note("$stage DeviceInfo parse failed ${describe(it)}") }
        }
    }

    private suspend fun command(
        camera: NikonCamera,
        stage: String,
        operation: Int,
        vararg parameters: Int,
    ): Pair<Int, ByteArray?> {
        currentCoroutineContext().ensureActive()
        val begin = SystemClock.elapsedRealtime()
        try {
            camera.sendCmd(operation, *parameters)
            return camera.recvRespWithPayload().also { (rc, bytes) ->
                note("$stage op=${hex(operation)} params=${parameters.joinToString { hex(it) }} rc=${hex(rc)} bytes=${bytes?.size ?: 0} ms=${SystemClock.elapsedRealtime() - begin}")
            }
        } catch (error: Exception) {
            note("$stage op=${hex(operation)} transport=${describe(error)} ms=${SystemClock.elapsedRealtime() - begin}")
            throw error
        }
    }

    private fun requireOk(reply: Pair<Int, ByteArray?>, operation: String) {
        if (reply.first != Lab.OK) throw IOException("$operation rejected ${hex(reply.first)}")
    }

    private fun phase(context: Context, label: String, stage: String) {
        mutableState.update { it.copy(phase = label) }
        note("--- $stage ---")
        persist(context, snapshot(context))
    }

    private fun note(line: String) = synchronized(lock) {
        val entry = "+${(SystemClock.elapsedRealtime() - startedMs).coerceAtLeast(0)}ms $line\n"
        if (report.length + entry.length <= MAX_REPORT_CHARACTERS) report.append(entry)
    }

    private fun persist(context: Context, text: String) {
        runCatching {
            val destination = File(context.filesDir, REPORT_FILE)
            val temporary = File(context.filesDir, "$REPORT_FILE.tmp")
            temporary.writeText(text)
            if (!temporary.renameTo(destination)) {
                destination.writeText(text)
                temporary.delete()
            }
        }
    }

    private fun describe(error: Throwable): String =
        "${error.javaClass.simpleName}:${error.message.orEmpty().take(240).replace('\n', ' ')}"
    private fun hex(value: Int): String = "0x%04X".format(value and 0xFFFF)
}
