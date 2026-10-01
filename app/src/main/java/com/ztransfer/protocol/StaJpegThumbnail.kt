package com.ztransfer.protocol

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.ByteArrayOutputStream
import kotlin.math.roundToInt

internal const val STA_JPEG_THUMBNAIL_EDGE = 640
internal const val STA_JPEG_THUMBNAIL_MAX_BYTES = 256 * 1024

/** Select one independent preview, never the primary JPEG, and never download several candidates. */
internal fun selectStaJpegThumbnailPreview(
    references: List<JpegMpfPreviewReference>,
): JpegMpfPreviewReference? = references
    .filter {
        it.offset > 0 && it.imageType in 0x010001..0x010005 &&
            it.length in 4..STA_JPEG_THUMBNAIL_MAX_BYTES
    }
    .minByOrNull { it.length }

internal fun jpegThumbnailLongEdge(bytes: ByteArray?): Int {
    if (bytes == null) return 0
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    return if (bounds.outWidth > 0 && bounds.outHeight > 0) {
        maxOf(bounds.outWidth, bounds.outHeight)
    } else 0
}

/** Decode at a bounded size; keep pixel orientation consistent with existing grid thumbnails. */
internal fun createStaJpegThumbnail(bytes: ByteArray, fallbackLongEdge: Int): ByteArray? {
    if (bytes.size !in 4..STA_JPEG_THUMBNAIL_MAX_BYTES ||
        bytes[0] != 0xFF.toByte() || bytes[1] != 0xD8.toByte() ||
        bytes[bytes.lastIndex - 1] != 0xFF.toByte() || bytes.last() != 0xD9.toByte()
    ) return null
    val longEdge = jpegThumbnailLongEdge(bytes)
    if (minOf(longEdge, STA_JPEG_THUMBNAIL_EDGE) <= fallbackLongEdge) return null
    var sample = 1
    while (longEdge / sample > STA_JPEG_THUMBNAIL_EDGE * 2) sample *= 2
    val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply {
        inSampleSize = sample
    }) ?: return null
    var scaled: Bitmap? = null
    return try {
        val decodedEdge = maxOf(decoded.width, decoded.height)
        val output = if (decodedEdge > STA_JPEG_THUMBNAIL_EDGE) {
            val ratio = STA_JPEG_THUMBNAIL_EDGE.toDouble() / decodedEdge
            Bitmap.createScaledBitmap(
                decoded,
                (decoded.width * ratio).roundToInt().coerceAtLeast(1),
                (decoded.height * ratio).roundToInt().coerceAtLeast(1),
                true,
            ).also { scaled = it }
        } else decoded
        ByteArrayOutputStream().use { stream ->
            if (output.compress(Bitmap.CompressFormat.JPEG, 90, stream)) stream.toByteArray() else null
        }
    } finally {
        if (scaled !== decoded) scaled?.recycle()
        decoded.recycle()
    }
}
