"""Exact original preview EXIF extraction. Unlike photo-frame metadata, this keeps Float quirks."""
import re
import textwrap

BASELINE = '9a84fc9'
ANDROID = 'app/src/main/java/com/ztransfer/viewmodel/CameraViewModel.kt'
COMMON = 'shared/src/commonMain/kotlin/com/ztransfer/preview/PreviewExifPolicy.kt'
ADAPTER = 'app/src/main/java/com/ztransfer/viewmodel/AndroidPreviewExif.kt'
ORACLE = 'app/src/test/java/com/ztransfer/previewbaseline/PreviewExifBaseline.kt'


def section(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]


def parts(original):
    rational = section(original, '    private fun parseRational(', '\n    /**\n     * 解析文件头字节中的 EXIF')
    parse = section(original, '    private fun parseExifImpl(', '\n    private fun parseGpsCoordinate(')
    gps = section(original, '    private fun parseGpsCoordinate(', '\n    private fun thumbnailDiskCacheFileName(')
    return rational, parse, gps


def abstract_body(original):
    body = '\n'.join(textwrap.dedent(part).rstrip() for part in parts(original)) + '\n'
    return (body.replace('exif: ExifInterface', 'exif: PreviewExifSource')
        .replace('ExifInterface.TAG_', 'PreviewExifTag.')
        .replace('exif.getAttribute', 'exif.attribute').replace('exif::getAttribute', 'exif::attribute')
        .replace('exif.latLong', 'exif.decodedCoordinates()')
        .replace('exif.getAltitude(Double.NaN)', 'exif.decodedAltitude()'))


def common(original):
    body = abstract_body(original)
    changes = [
        ('private fun parseRational', 'internal fun parsePreviewExifRational'),
        ('parseRational(', 'parsePreviewExifRational('),
        ('private fun parseExifImpl(exif: PreviewExifSource)', 'fun parsePreviewExif(exif: PreviewExifSource, formatter: PreviewExifDecimalFormatter)'),
        ('private fun parseGpsCoordinate', 'internal fun parsePreviewGpsCoordinate'),
        ('parseGpsCoordinate(', 'parsePreviewGpsCoordinate('),
        ('Math.pow(2.0, apex.toDouble() / 2.0)', '2.0.pow(apex.toDouble() / 2.0)'),
        ('"f/%.0f".format(f)', '("f/" + formatter.fixed(f, 0, false))'),
        ('"f/%.1f".format(f)', '("f/" + formatter.fixed(f, 1, false))'),
        ('"%.1fs".format(sec)', '(formatter.fixed(sec, 1, false) + "s")'),
        ('"1/%.0f".format(1f / sec)', '("1/" + formatter.fixed(1f / sec, 0, false))'),
        ('"%.0fmm".format(it)', '(formatter.fixed(it, 0, false) + "mm")'),
        ('''formatExposureCompensation(
        parsePreviewExifRational(exif.attribute(PreviewExifTag.EXPOSURE_BIAS_VALUE)),
    )''', '''exposureCompensationText(
        parsePreviewExifRational(exif.attribute(PreviewExifTag.EXPOSURE_BIAS_VALUE)),
    ) { formatter.fixed(it, 1, true) }'''),
    ]
    for before, after in changes:
        if before not in body: raise AssertionError(before)
        body = body.replace(before, after)
    return ('package com.ztransfer.preview\n\nimport com.ztransfer.viewmodel.PhotoExif\n'
            'import com.ztransfer.viewmodel.exposureCompensationText\nimport kotlin.math.pow\n\n' + body)


def android(original):
    rational, parse, gps = parts(original)
    result = original.replace(rational, '').replace(gps, '')
    result = result.replace(parse, '''    private fun parseExifImpl(exif: ExifInterface): PhotoExif? =
        com.ztransfer.preview.parsePreviewExif(AndroidPreviewExifSource(exif), AndroidPreviewExifDecimalFormatter)
''')
    result = result.replace('''    /**
     * 解析 ExifInterface RATIONAL/SRATIONAL 属性值（"num/denom" → Float）。
     * SHORT/LONG 等整数类型直接解析为 Float。null 或格式异常返回 null。
     */
''', '')
    return result


def adapter(original):
    tags = list(dict.fromkeys(re.findall(r'ExifInterface.TAG_(\w+)', parts(original)[1])))
    return '''package com.ztransfer.viewmodel

import androidx.exifinterface.media.ExifInterface
import com.ztransfer.preview.PreviewExifSource
import com.ztransfer.preview.PreviewExifTag
import com.ztransfer.preview.PreviewExifDecimalFormatter
import java.util.Locale

/** Lazy tag access preserves the original fallback evaluation order and Android numeric decoder. */
internal class AndroidPreviewExifSource(private val exif: ExifInterface) : PreviewExifSource {
    override fun attribute(tag: PreviewExifTag): String? = exif.getAttribute(when (tag) {
'''+''.join(f'        PreviewExifTag.{tag} -> ExifInterface.TAG_{tag}\n' for tag in tags)+'''    })
    override fun decodedCoordinates(): DoubleArray? = exif.latLong
    override fun decodedAltitude(): Double = exif.getAltitude(Double.NaN)
}

internal object AndroidPreviewExifDecimalFormatter : PreviewExifDecimalFormatter {
    override fun fixed(value: Float, fractionDigits: Int, rootLocale: Boolean): String =
        if (rootLocale) String.format(Locale.ROOT, "%.${fractionDigits}f", value)
        else "%.${fractionDigits}f".format(value)
}
'''


def oracle(original):
    return ('''package com.ztransfer.previewbaseline

import com.ztransfer.preview.PreviewExifSource
import com.ztransfer.preview.PreviewExifTag
import com.ztransfer.viewmodel.PhotoExif
import com.ztransfer.viewmodel.formatExposureCompensation

''' + abstract_body(original).replace('private fun parseExifImpl(', 'internal fun parseExifImpl('))
