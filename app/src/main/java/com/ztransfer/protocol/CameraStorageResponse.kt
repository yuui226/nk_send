package com.ztransfer.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** A rejected or incomplete GetStorageIDs response is not evidence that a card was removed. */
internal fun parseCameraStorageIdsResponse(response: Int, data: ByteArray?): NikonCamera.StorageIdsResult {
    if (response != PtpConstants.RESPONSE_OK || data == null || data.size < 4) {
        return NikonCamera.StorageIdsResult(emptyList(), false, response, data?.size ?: 0)
    }
    val buffer = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
    val count = buffer.int
    if (count < 0 || count > (data.size - 4) / 4) {
        return NikonCamera.StorageIdsResult(emptyList(), false, response, data.size, "malformed-count=$count")
    }
    return NikonCamera.StorageIdsResult(List(count) { buffer.int }, true, response, data.size)
}
