"""Exact extraction of the existing RAW parser; no IO, policy or algorithm rewrite."""
BASELINE = '073188f'
ANDROID = 'app/src/main/java/com/ztransfer/protocol/NikonCamera.kt'
COMMON = 'shared/src/commonMain/kotlin/com/ztransfer/preview/NefPreviewMetadata.kt'


def section(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]


def parts(original):
    date = section(original, 'internal fun staDirectCaptureDate(', '\n/**\n * Builds a complete minimal JPEG')
    reference = 'internal data class NefPreviewReference(val offset: Long, val length: Int)'
    parser = section(original, '/** Returns the exact range of the largest complete JPEG', '\nprivate const val QUICKTIME_EPOCH_OFFSET_SECONDS')
    return date, reference, parser


def common(original):
    date, reference, parser = parts(original)
    body = (date + '\n' + reference + '\n\n' + parser).replace('internal ', '')
    # JVM US_ASCII replaces EACH non-ASCII byte with U+FFFD, not UTF-8 decoding.
    body = body.replace('.toString(Charsets.US_ASCII)', '.decodeRawAscii()')
    return ('package com.ztransfer.preview\n\n' + body +
            '\nprivate const val STA_DIRECT_MAX_EMBEDDED_PREVIEW_BYTES = 16 * 1024 * 1024\n\n' +
            'internal fun ByteArray.decodeRawAscii(): String = buildString(size) {\n' +
            '    for (byte in this@decodeRawAscii) {\n' +
            "        append(if (byte >= 0) byte.toInt().toChar() else '\\uFFFD')\n" +
            '    }\n}\n')


def android(original):
    date, reference, parser = parts(original)
    result = original.replace(date,
        'internal fun staDirectCaptureDate(exifDate: String?): String? =\n'
        '    com.ztransfer.preview.staDirectCaptureDate(exifDate)\n')
    result = result.replace(reference,
        'internal typealias NefPreviewReference = com.ztransfer.preview.NefPreviewReference')
    wrappers = '''/** Pure RAW parsing is shared; Android IO and preview selection remain unchanged. */
internal fun largestEmbeddedJpegRange(
    bytes: ByteArray,
    validLength: Int = bytes.size,
): NefPreviewReference? = com.ztransfer.preview.largestEmbeddedJpegRange(bytes, validLength)

internal fun largestEmbeddedJpeg(bytes: ByteArray): ByteArray? =
    com.ztransfer.preview.largestEmbeddedJpeg(bytes)

internal typealias NefHeaderMetadata = com.ztransfer.preview.NefHeaderMetadata

internal fun parseNefHeaderMetadata(
    bytes: ByteArray,
    validLength: Int = bytes.size,
): NefHeaderMetadata = com.ztransfer.preview.parseNefHeaderMetadata(bytes, validLength)
'''
    return result.replace(parser, wrappers)


def oracle(original):
    date, reference, parser = parts(original)
    return ('package com.ztransfer.protocol.rawbaseline\n\n' + date + '\n' + reference +
            '\n\n' + parser +
            '\nprivate const val STA_DIRECT_MAX_EMBEDDED_PREVIEW_BYTES = 16 * 1024 * 1024\n')
