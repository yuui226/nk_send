package com.ztransfer.protocol

import android.graphics.BitmapFactory
import android.os.SystemClock
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** A fresh pairing must return a real remote frame before it can be persisted or activated. */
internal suspend fun NikonCamera.verifyStaPairingLiveView(log: (String) -> Unit) {
    var validFrame = false
    var remoteRequestAttempted = false
    try {
        withCameraTransaction(CameraRequestKind.INTERACTIVE, "STA_PAIRING_PERMISSION") {
            withContext(Dispatchers.IO) {
                val previousTimeout = setCommandReadTimeout(5_000)
                val deadline = SystemClock.elapsedRealtime() + 8_000L
                var streamUsable = true
                var startedHere = false

                suspend fun command(code: Int, vararg params: Int, cleanup: Boolean = false): Pair<Int, ByteArray?> {
                    currentCoroutineContext().ensureActive()
                    val remaining = if (cleanup) 5_000L else deadline - SystemClock.elapsedRealtime()
                    if (remaining <= 0L) throw IOException("STA remote permission timed out")
                    setCommandReadTimeout(remaining.coerceAtMost(5_000L).toInt())
                    try {
                        if (code == Lab.NK_START_LIVE_VIEW || code == Lab.NK_GET_LIVE_VIEW_IMG ||
                            code == Lab.NK_GET_LIVE_VIEW_IMG_EX
                        ) {
                            remoteRequestAttempted = true
                            log("pairing live-view request=0x${code.toString(16)}")
                        }
                        sendCmd(code, *params)
                        return recvRespWithPayload().also { (rc, data) ->
                            log("pairing live-view op=0x${code.toString(16)} rc=0x${rc.toString(16)} bytes=${data?.size ?: 0}")
                        }
                    } catch (error: Exception) {
                        // Timeout/EOF may leave a partial packet. Never send cleanup on that stream.
                        streamUsable = false
                        abortProtocolTransport()
                        throw error
                    }
                }

                try {
                    // This property only preserves the original state; it is NOT pairing evidence.
                    val (statusRc, statusData) = command(Lab.GET_DEVICE_PROP_VALUE, Lab.PROP_NK_LV_STATUS)
                    val initialStatus = statusData?.singleOrNull()?.toInt()?.and(0xFF)
                    if (statusRc != Lab.OK || initialStatus !in 0..1) {
                        throw IOException("STA initial Live View state unavailable")
                    }
                    if (initialStatus == 0) {
                        var start = command(Lab.NK_START_LIVE_VIEW).first
                        var retry = 0
                        while ((start == Lab.DEVICE_BUSY || start == 0xA004) && retry++ < 5) {
                            delay(200)
                            start = command(Lab.NK_START_LIVE_VIEW).first
                        }
                        if (start != Lab.OK) throw IOException("STA Live View start rejected: 0x${start.toString(16)}")
                        startedHere = true
                        var ready = command(Lab.NK_DEVICE_READY).first
                        retry = 0
                        while (ready == Lab.DEVICE_BUSY && retry++ < 20) {
                            delay(100)
                            ready = command(Lab.NK_DEVICE_READY).first
                        }
                        // Some models do not implement DeviceReady. The actual frame is decisive.
                    }

                    var operation = if (cachedDeviceInfo?.operations?.contains(Lab.NK_GET_LIVE_VIEW_IMG_EX) == true) {
                        Lab.NK_GET_LIVE_VIEW_IMG_EX
                    } else Lab.NK_GET_LIVE_VIEW_IMG
                    var enhancedFailures = 0
                    while (SystemClock.elapsedRealtime() < deadline) {
                        val (rc, data) = command(operation)
                        if (rc == Lab.OK && data != null && validStaPairingFrame(data)) {
                            validFrame = true
                            log("pairing live-view=VALID_FRAME")
                            break
                        }
                        val warmingUp = rc == Lab.DEVICE_BUSY || rc == Lab.NK_NOT_LIVE_VIEW
                        if (operation == Lab.NK_GET_LIVE_VIEW_IMG_EX && !warmingUp &&
                            (rc == PtpConstants.OPERATION_NOT_SUPPORTED || ++enhancedFailures >= 2)
                        ) {
                            operation = Lab.NK_GET_LIVE_VIEW_IMG
                            // Switching an unsupported/invalid format is not camera warm-up.
                            // Try the standard operation immediately; its busy response, if any,
                            // still uses the same bounded retry delay below.
                            continue
                        } else if (rc != Lab.OK && !warmingUp && operation == Lab.NK_GET_LIVE_VIEW_IMG) {
                            throw IOException("STA Live View frame rejected: 0x${rc.toString(16)}")
                        }
                        delay(100)
                    }
                    if (!validFrame) throw IOException("STA Live View did not return a valid JPEG")
                } finally {
                    try {
                        if (startedHere && streamUsable) {
                            withContext(NonCancellable) {
                                val end = command(Lab.NK_END_LIVE_VIEW, cleanup = true).first
                                if (end != Lab.OK && end != Lab.NK_NOT_LIVE_VIEW) {
                                    abortProtocolTransport()
                                    throw IOException("STA Live View cleanup rejected: 0x${end.toString(16)}")
                                }
                            }
                        }
                    } finally {
                        runCatching { restoreCommandReadTimeout(previousTimeout) }
                    }
                }
            }
        }
    } catch (error: Exception) {
        // Cleanup must not convert a user cancellation into an automatic pairing recovery.
        currentCoroutineContext().ensureActive()
        if (error is CancellationException) throw error
        val verifiedGuid = staResponderGuid
        if (validFrame && verifiedGuid != null) {
            log("pairing live-view=VERIFIED cleanup=FAILED reason=${error.javaClass.simpleName}:${error.message.orEmpty()}")
            throw StaPairingCleanupException(
                StaPairingConfirmation(verifiedGuid, remotePermissionVerified = true), error)
        }
        log("pairing live-view=UNCONFIRMED reason=${error.javaClass.simpleName}:${error.message.orEmpty()}")
        throw PairingNotConfirmedException(error, remoteRequestAttempted = remoteRequestAttempted)
    }
}

/** Finishes only the Live View started by this pairing attempt, without repeating pairing or frames. */
internal suspend fun NikonCamera.finishStaPairingLiveViewCleanup(
    confirmation: StaPairingConfirmation,
    log: (String) -> Unit,
) {
    try {
        withCameraTransaction(CameraRequestKind.INTERACTIVE, "STA_PAIRING_CLEANUP") {
            withContext(Dispatchers.IO) {
                val previousTimeout = setCommandReadTimeout(5_000)
                val deadline = SystemClock.elapsedRealtime() + 5_000L
                try {
                    check(confirmation.remotePermissionVerified && staResponderGuid == confirmation.responderGuid) {
                        "STA cleanup requires this camera's verified pairing attempt"
                    }
                    fun remainingMillis(): Long {
                        val remaining = deadline - SystemClock.elapsedRealtime()
                        if (remaining <= 0L) throw IOException("STA Live View cleanup timed out")
                        return remaining
                    }
                    suspend fun command(code: Int, vararg params: Int): Pair<Int, ByteArray?> {
                        currentCoroutineContext().ensureActive()
                        setCommandReadTimeout(remainingMillis().coerceAtMost(5_000L).toInt())
                        sendCmd(code, *params)
                        return recvRespWithPayload().also { (rc, data) ->
                            log("pairing cleanup op=0x${code.toString(16)} rc=0x${rc.toString(16)} bytes=${data?.size ?: 0}")
                        }
                    }
                    suspend fun readStatus(): Int {
                        val (rc, data) = command(Lab.GET_DEVICE_PROP_VALUE, Lab.PROP_NK_LV_STATUS)
                        val status = data?.singleOrNull()?.toInt()?.and(0xFF)
                        if (rc != Lab.OK || status !in 0..1) {
                            throw IOException("STA Live View cleanup state unavailable")
                        }
                        return checkNotNull(status)
                    }

                    if (readStatus() == 1) {
                        val end = command(Lab.NK_END_LIVE_VIEW).first
                        if (end != Lab.OK && end != Lab.NK_NOT_LIVE_VIEW) {
                            throw IOException("STA Live View cleanup rejected: 0x${end.toString(16)}")
                        }
                        // An ACK is not proof of the final state. Do not send EndLiveView again.
                        while (readStatus() != 0) {
                            delay(remainingMillis().coerceAtMost(100L))
                        }
                    }
                    log("pairing cleanup=STOPPED")
                } catch (error: Exception) {
                    // Do not reuse a failed or partially consumed stream, including on cancellation.
                    abortProtocolTransport()
                    throw error
                } finally {
                    runCatching { restoreCommandReadTimeout(previousTimeout) }
                }
            }
        }
    } catch (error: Exception) {
        currentCoroutineContext().ensureActive()
        if (error is CancellationException) throw error
        log("pairing cleanup=FAILED reason=${error.javaClass.simpleName}:${error.message.orEmpty()}")
        // The original frame remains proven. The caller must stop, never restart pairing again.
        throw StaPairingCleanupException(confirmation, error)
    }
}

private fun validStaPairingFrame(data: ByteArray): Boolean {
    val jpeg = largestEmbeddedJpegRange(data) ?: return false
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(data, jpeg.offset.toInt(), jpeg.length, bounds)
    return bounds.outWidth > 0 && bounds.outHeight > 0 && bounds.outMimeType == "image/jpeg"
}
