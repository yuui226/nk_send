package com.ztransfer.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.withLock

/** PTP StorageInfo fixed fields; unknown UINT64 values must never become a capacity. */
internal fun parseMonitorFreeBytes(data: ByteArray): Long? {
    if (data.size < 26) return null
    val buffer = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
    val capacity = buffer.getLong(6)
    val free = buffer.getLong(14)
    return free.takeIf { capacity > 0 && it >= 0 && it <= capacity }
}

internal data class MonitorStorageRead(val freeBytes: Long? = null, val unsupported: Boolean = false)

/** Standard GetStorageInfo, serialized with every other camera transaction. */
internal suspend fun NikonCamera.monitorFreeBytes(storageId: Int, allowed: () -> Boolean): MonitorStorageRead = ioMutex.withLock {
    if (!allowed()) return@withLock MonitorStorageRead()
    withContext(Dispatchers.IO) {
        sendCmd(0x1005, storageId)
        val (response, data) = recvRespWithPayload()
        MonitorStorageRead(
            freeBytes = if (response == PtpConstants.RESPONSE_OK && data != null) parseMonitorFreeBytes(data) else null,
            unsupported = response == 0x2005, // OperationNotSupported, not DeviceBusy or a temporary error.
        )
    }
}
