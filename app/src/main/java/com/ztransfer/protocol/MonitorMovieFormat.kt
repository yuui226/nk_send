package com.ztransfer.protocol

/** D0A0 UINT64: Z30 sample 00003C0038048007 -> flags=0, rate=60, height=1080, width=1920. */
internal fun monitorMovieFormatLabel(dataType: Int, raw: Long): String? {
    // Older cameras use unrelated UINT8 enumerations: never apply this packed layout to them.
    if (dataType != 0x0008) return null
    val flags = (raw and 0xffff).toInt()
    val rate = ((raw ushr 16) and 0xffff).toInt()
    val height = ((raw ushr 32) and 0xffff).toInt()
    val width = ((raw ushr 48) and 0xffff).toInt()
    // Slow-motion flags have not been verified against the camera yet.
    if (flags != 0 || rate !in 1..480) return null
    val resolution = when (width to height) {
        1920 to 1080 -> "1080"
        3840 to 2160 -> "4K"
        1280 to 720 -> "720"
        else -> return null
    }
    return "$resolution ${rate}p"
}
