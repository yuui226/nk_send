package com.ztransfer.protocol

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * A delayed shutter may be invalidated while waiting for the camera or between busy responses.
 * Only a command already sent is non-cancellable, so its complete response is always consumed.
 * Returns null when the request is no longer current, without sending another shutter command.
 */
internal suspend fun NikonCamera.rcCaptureIfCurrent(isCurrent: () -> Boolean): Int? =
    runDelayedCapture(
        isCurrent = isCurrent,
        command = {
            if (!isCurrent()) null else focusMutex.withLock {
                if (!isCurrent()) null else {
                    withCameraTransaction(CameraRequestKind.INTERACTIVE, "REMOTE_DELAYED_CAPTURE") {
                        withContext(Dispatchers.IO) {
                            if (!isCurrent()) null else withContext(NonCancellable) {
                                // Check after both queues and the dispatcher hop, directly before I/O.
                                if (!isCurrent()) null else {
                                    sendCmd(Lab.NK_CAPTURE_REC_IN_MEDIA, -1 /* no AF */, 0 /* card */)
                                    recvRespWithPayload().first
                                }
                            }
                        }
                    }
                }
            }
        },
        pause = { delay(it) },
    )

/** The normal shutter's five busy retries, with an invalidation check before each attempt. */
internal suspend fun runDelayedCapture(
    isCurrent: () -> Boolean,
    command: suspend () -> Int?,
    pause: suspend (Long) -> Unit,
): Int? {
    var retries = 0
    while (true) {
        if (!isCurrent()) return null
        val response = command() ?: return null
        if (response != Lab.DEVICE_BUSY || retries >= 5) return response
        pause(200)
        retries++
    }
}
