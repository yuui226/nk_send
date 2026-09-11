package com.ztransfer.protocol

/**
 * Decodes a PTP AUINT32 dataset while preserving the camera's original order and bit patterns.
 *
 * A valid zero-count dataset returns an empty list. Missing/truncated data and impossible counts
 * return `null`, allowing platform transports to distinguish an empty camera catalog from a
 * malformed response. Bytes after the declared array are intentionally ignored, matching the
 * existing Android behavior.
 */
fun parsePtpUInt32Array(data: ByteArray?): List<Int>? {
    if (data == null || data.size < Int.SIZE_BYTES) return null
    val count = data.readInt32LittleEndian(0)
    if (count < 0 || count > (data.size - Int.SIZE_BYTES) / Int.SIZE_BYTES) return null
    return List(count) { index ->
        data.readInt32LittleEndian(Int.SIZE_BYTES + index * Int.SIZE_BYTES)
    }
}
