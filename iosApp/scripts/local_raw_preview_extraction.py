"""Enumerated extraction of Android local RAW selection; every other IO/decode line stays."""


def android(original):
    replacements = [
        ('import com.ztransfer.protocol.largestEmbeddedJpegRange\nimport com.ztransfer.protocol.parseNefHeaderMetadata',
         'import com.ztransfer.preview.LocalRawPreviewPolicy'),
        ('private const val LOCAL_RAW_PREVIEW_INDEX_BYTES = 16 * 1024 * 1024',
         'private const val LOCAL_RAW_PREVIEW_INDEX_BYTES = LocalRawPreviewPolicy.indexPrefixBytes'),
        ('''        val references = buildList {
            addAll(parseNefHeaderMetadata(prefix).previews)
            largestEmbeddedJpegRange(prefix)?.let(::add)
        }.distinct()''', '        val references = LocalRawPreviewPolicy.candidates(prefix)'),
        ('''            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return@forEach
            val pixels = bounds.outWidth.toLong() * bounds.outHeight.toLong()
            if (pixels > bestPixels) {''', '''            val pixels = LocalRawPreviewPolicy.pixelCount(bounds.outWidth, bounds.outHeight)
            if (LocalRawPreviewPolicy.isBetter(pixels, bestPixels)) {'''),
        ('''        return bytes.takeIf {
            it.size >= 4 &&
                it[0] == 0xFF.toByte() && it[1] == 0xD8.toByte() &&
                it[it.lastIndex - 1] == 0xFF.toByte() && it[it.lastIndex] == 0xD9.toByte()
        }''', '        return bytes.takeIf(LocalRawPreviewPolicy::isCompleteJpeg)'),
    ]
    for before, after in replacements:
        if original.count(before) != 1:
            raise AssertionError('Expected exactly one original RAW selection boundary: ' + before)
        original = original.replace(before, after, 1)
    return original
