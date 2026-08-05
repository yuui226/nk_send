package com.ztransfer.filter

import java.security.MessageDigest

private const val NP3_SIMPLE_LENGTH = 392
private const val NP3_NAME_OFFSET = 0x18
private const val NP3_NAME_LENGTH = 19
private const val NP3_TONE_CURVE_FLAG_OFFSET = 0x187

private val BASIC_OFFSETS = intArrayOf(0x110, 0x11a, 0x124, 0x12e, 0x138, 0x142)
private val COLOR_BLENDER_OFFSETS = intArrayOf(
    0x14c,
    0x14f,
    0x152,
    0x155,
    0x158,
    0x15b,
    0x15e,
    0x161,
)
private val COLOR_GRADING_OFFSETS = intArrayOf(0x170, 0x174, 0x178)
internal val NP3_COLOR_BAND_CENTERS = floatArrayOf(
    0f,
    30f,
    60f,
    120f,
    180f,
    240f,
    280f,
    320f,
)

/**
 * App 可稳定近似的 NP3 子集。
 *
 * 只保留基础明暗与 Flexible Color 的八段颜色混合器。自定义曲线和三路色彩分级
 * 依赖 Nikon 未公开的处理顺序与颜色空间，解析时直接拒绝，绝不静默丢参数。
 */
data class Np3PhotoFilter(
    val id: String,
    val name: String,
    val contrast: Int,
    val highlights: Int,
    val shadows: Int,
    val whiteLevel: Int,
    val blackLevel: Int,
    val saturation: Int,
    val colorBands: List<Np3ColorBand>,
)

data class Np3ColorBand(
    val centerDegrees: Float,
    val hue: Int,
    val chroma: Int,
    val brightness: Int,
)

data class PhotoFilterSelection(
    val preset: Np3PhotoFilter,
    val intensityPercent: Int,
) {
    val normalizedIntensityPercent: Int
        get() = normalizePhotoFilterIntensity(intensityPercent)
}

enum class Np3FilterRejection {
    INVALID_FILE,
    CUSTOM_TONE_CURVE,
    COLOR_GRADING,
}

class Np3FilterException(
    val rejection: Np3FilterRejection,
) : IllegalArgumentException(rejection.name)

fun normalizePhotoFilterIntensity(value: Int): Int = value.coerceIn(0, 100)

object Np3PhotoFilterParser {
    fun parse(bytes: ByteArray): Np3PhotoFilter {
        if (bytes.size < NP3_SIMPLE_LENGTH || !hasNp3Magic(bytes)) {
            throw Np3FilterException(Np3FilterRejection.INVALID_FILE)
        }
        if (bytes.size != NP3_SIMPLE_LENGTH || unsigned(bytes[NP3_TONE_CURVE_FLAG_OFFSET]) == 2) {
            throw Np3FilterException(Np3FilterRejection.CUSTOM_TONE_CURVE)
        }
        if (usesColorGrading(bytes)) {
            throw Np3FilterException(Np3FilterRejection.COLOR_GRADING)
        }
        val name = readName(bytes)
        if (name.isBlank()) throw Np3FilterException(Np3FilterRejection.INVALID_FILE)

        val basic = BASIC_OFFSETS.map { signedSetting(bytes, it) }
        val bands = COLOR_BLENDER_OFFSETS.mapIndexed { index, offset ->
            Np3ColorBand(
                centerDegrees = NP3_COLOR_BAND_CENTERS[index],
                hue = signedSetting(bytes, offset),
                chroma = signedSetting(bytes, offset + 1),
                brightness = signedSetting(bytes, offset + 2),
            )
        }
        return Np3PhotoFilter(
            id = sha256(bytes),
            name = name,
            contrast = basic[0],
            highlights = basic[1],
            shadows = basic[2],
            whiteLevel = basic[3],
            blackLevel = basic[4],
            saturation = basic[5],
            colorBands = bands,
        )
    }

    private fun hasNp3Magic(bytes: ByteArray): Boolean =
        bytes[0] == 'N'.code.toByte() &&
            bytes[1] == 'C'.code.toByte() &&
            bytes[2] == 'P'.code.toByte() &&
            bytes[3] == 0.toByte()

    private fun readName(bytes: ByteArray): String {
        val end = (NP3_NAME_OFFSET until NP3_NAME_OFFSET + NP3_NAME_LENGTH)
            .firstOrNull { bytes[it] == 0.toByte() }
            ?: (NP3_NAME_OFFSET + NP3_NAME_LENGTH)
        return bytes.copyOfRange(NP3_NAME_OFFSET, end)
            .toString(Charsets.US_ASCII)
            .trim()
            .filter { it.code in 0x20..0x7e }
    }

    private fun usesColorGrading(bytes: ByteArray): Boolean =
        COLOR_GRADING_OFFSETS.any { offset ->
            signedSetting(bytes, offset + 2) != 0 || signedSetting(bytes, offset + 3) != 0
        }

    private fun signedSetting(bytes: ByteArray, offset: Int): Int =
        (unsigned(bytes[offset]) - 0x80).coerceIn(-100, 100)

    private fun unsigned(value: Byte): Int = value.toInt() and 0xff

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes)
        .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
}

/** 两个相邻色域之间的环形线性权重；供渲染器和纯 JVM 测试共用。 */
internal fun adjacentColorBandWeights(
    hueDegrees: Float,
    centers: List<Float>,
): Triple<Int, Int, Float> {
    require(centers.size >= 2)
    val hue = ((hueDegrees % 360f) + 360f) % 360f
    for (index in centers.indices) {
        val next = (index + 1) % centers.size
        val start = centers[index]
        val end = if (next == 0) centers[0] + 360f else centers[next]
        val adjustedHue = if (next == 0 && hue < start) hue + 360f else hue
        if (adjustedHue in start..end) {
            val progress = ((adjustedHue - start) / (end - start)).coerceIn(0f, 1f)
            return Triple(index, next, progress)
        }
    }
    return Triple(0, 1, 0f)
}
