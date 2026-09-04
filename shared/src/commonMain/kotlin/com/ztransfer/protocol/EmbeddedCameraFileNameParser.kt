package com.ztransfer.protocol

data class EmbeddedCameraFileName(
    val offset: Int,
    val value: String,
    val encoding: String,
)

private val CAMERA_MEDIA_EXTENSIONS = setOf("jpg", "jpeg", "nef", "mov", "mp4")

private fun isPlausibleCameraFileName(value: String): Boolean {
    val dot = value.lastIndexOf('.')
    if (dot !in 1 until value.lastIndex) return false
    val stem = value.substring(0, dot)
    val extension = value.substring(dot + 1).lowercase()
    return extension in CAMERA_MEDIA_EXTENSIONS &&
        stem.length in 2..32 &&
        stem.any(Char::isDigit) &&
        stem.all { it.isLetterOrDigit() || it == '_' || it == '-' }
}

/** Finds filename-shaped PTP strings or plain ASCII fields in Nikon metadata/file headers. */
fun findEmbeddedCameraFileNames(
    data: ByteArray,
    includePtpStrings: Boolean = true,
): List<EmbeddedCameraFileName> {
    val results = LinkedHashMap<String, EmbeddedCameraFileName>()
    if (includePtpStrings) {
        data.indices.forEach { offset ->
            val declaredLength = data[offset].toInt() and 0xFF
            if (declaredLength !in 6..40) return@forEach
            parsePtpObjectFileName(data, offset)?.first
                ?.takeIf(::isPlausibleCameraFileName)
                ?.let { name ->
                    results.putIfAbsent(
                        "$offset:$name",
                        EmbeddedCameraFileName(offset, name, "ptp-string"),
                    )
                }
        }
    }

    fun isStemByte(value: Int): Boolean =
        value in 'A'.code..'Z'.code ||
            value in 'a'.code..'z'.code ||
            value in '0'.code..'9'.code ||
            value == '_'.code || value == '-'.code

    var dot = 2
    while (dot + 4 <= data.size) {
        if (data[dot] != '.'.code.toByte()) {
            dot++
            continue
        }
        var end = dot + 1
        while (end < data.size && end - dot <= 5 && isStemByte(data[end].toInt() and 0xFF)) end++
        var start = dot - 1
        while (start >= 0 && dot - start <= 32 && isStemByte(data[start].toInt() and 0xFF)) start--
        start++
        if (start < dot && end > dot + 1) {
            val candidate = buildString(end - start) {
                for (index in start until end) append((data[index].toInt() and 0xFF).toChar())
            }
            if (isPlausibleCameraFileName(candidate)) {
                results.putIfAbsent(
                    "$start:$candidate",
                    EmbeddedCameraFileName(start, candidate, "ascii"),
                )
            }
        }
        dot++
    }
    return results.values.toList()
}
