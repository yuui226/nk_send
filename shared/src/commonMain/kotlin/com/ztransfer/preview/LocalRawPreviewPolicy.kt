package com.ztransfer.preview

/** Original PhotoFrameExporter rules. IO and image-header decoding remain platform adapters. */
object LocalRawPreviewPolicy {
    const val indexPrefixBytes: Int = 16 * 1024 * 1024

    fun candidates(prefix: ByteArray): List<NefPreviewReference> = buildList {
        addAll(parseNefHeaderMetadata(prefix).previews)
        largestEmbeddedJpegRange(prefix)?.let(::add)
    }.distinct()

    fun pixelCount(width: Int, height: Int): Long =
        if (width <= 0 || height <= 0) -1L else width.toLong() * height.toLong()

    fun isBetter(pixelCount: Long, previous: Long): Boolean = pixelCount > 0L && pixelCount > previous

    fun hasJpegEnvelope(size: Long, first: Int, second: Int, penultimate: Int, last: Int): Boolean =
        size >= 4 && first == 0xFF && second == 0xD8 && penultimate == 0xFF && last == 0xD9

    fun isCompleteJpeg(bytes: ByteArray): Boolean = bytes.size >= 4 && hasJpegEnvelope(
        bytes.size.toLong(), bytes[0].toInt() and 255, bytes[1].toInt() and 255,
        bytes[bytes.lastIndex - 1].toInt() and 255, bytes[bytes.lastIndex].toInt() and 255,
    )
}
