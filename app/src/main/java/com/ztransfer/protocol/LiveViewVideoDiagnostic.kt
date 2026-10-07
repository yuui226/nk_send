package com.ztransfer.protocol

/** One read only: does not switch the normal live-view operation or camera mode. */
internal suspend fun NikonCamera.probeLegacyVideoTime(): String {
    val (response, data) = labCommand(Lab.NK_GET_LIVE_VIEW_IMG)
    val payload = data ?: byteArrayOf()
    val jpeg = (0 until minOf(payload.size - 2, 2048).coerceAtLeast(0)).firstOrNull {
        payload[it] == 0xff.toByte() && payload[it + 1] == 0xd8.toByte() &&
            payload[it + 2] == 0xff.toByte()
    }
    val summary = "legacy op=9203 resp=${response.toString(16)} bytes=${payload.size} header=$jpeg"
    if (response != 0x2001 || jpeg != 384) return "$summary; unsupported layout, no interpretation"
    fun u16(offset: Int) = ((payload[offset].toInt() and 255) shl 8) or
        (payload[offset + 1].toInt() and 255)
    return "$summary\nremaining words[64,66]=${u16(64)},${u16(66)} recording[68]=${payload[68].toInt() and 255}; compare with camera time"
}
