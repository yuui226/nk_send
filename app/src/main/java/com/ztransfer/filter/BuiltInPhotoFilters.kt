package com.ztransfer.filter

import com.ztransfer.R
import java.security.MessageDigest
import java.util.Locale

/**
 * 由应用自己维护的首发滤镜，不依赖来源不明的外部预设文件。
 *
 * 所有参数都严格落在当前渲染器能够完整表达的基础明暗、全局饱和度和八段 HSL 内；
 * 修改任何参数都会产生新的内容 ID，避免旧效果图被错误当成新版结果。
 */
object BuiltInPhotoFilters {
    val all: List<Np3PhotoFilter> by lazy {
        listOf(
            preset(
                key = "natural-v1",
                internalName = "Natural",
                contrast = 12,
                highlights = -18,
                shadows = 10,
                whiteLevel = 5,
                blackLevel = -6,
                saturation = 7,
                bands = listOf(
                    band(0, chroma = 4, brightness = 2),
                    band(1, hue = -2, chroma = 8, brightness = 5),
                    band(2, hue = -5, chroma = -2, brightness = 3),
                    band(3, hue = 8, chroma = 6, brightness = -1),
                    band(4, hue = -3, chroma = 3, brightness = 2),
                    band(5, hue = -4, chroma = 7, brightness = -2),
                    band(6, chroma = -3),
                    band(7, chroma = -2),
                ),
            ),
            preset(
                key = "warm-film-v1",
                internalName = "Warm Film",
                contrast = -2,
                highlights = -22,
                shadows = 14,
                whiteLevel = -6,
                blackLevel = 12,
                saturation = -5,
                bands = listOf(
                    band(0, hue = -3, chroma = 3, brightness = 4),
                    band(1, hue = -5, chroma = 10, brightness = 7),
                    band(2, hue = -8, chroma = -5, brightness = 5),
                    band(3, hue = 10, chroma = -18, brightness = 2),
                    band(4, hue = 6, chroma = -15, brightness = 2),
                    band(5, hue = 8, chroma = -12, brightness = -2),
                    band(6, chroma = -20),
                    band(7, chroma = -10),
                ),
            ),
            preset(
                key = "teal-cinema-v1",
                internalName = "Teal Cinema",
                contrast = 18,
                highlights = -16,
                shadows = -4,
                whiteLevel = 2,
                blackLevel = -8,
                saturation = -7,
                bands = listOf(
                    band(0, hue = -4, chroma = 8, brightness = 2),
                    band(1, hue = -6, chroma = 12, brightness = 5),
                    band(2, hue = -10, chroma = -10),
                    band(3, hue = 15, chroma = -5, brightness = -4),
                    band(4, hue = -10, chroma = 14, brightness = -4),
                    band(5, hue = -18, chroma = 12, brightness = -8),
                    band(6, hue = -8, chroma = -10, brightness = -6),
                    band(7, chroma = -6),
                ),
            ),
            preset(
                key = "soft-portrait-v1",
                internalName = "Soft Portrait",
                contrast = -10,
                highlights = -20,
                shadows = 18,
                whiteLevel = 4,
                blackLevel = 10,
                saturation = -6,
                bands = listOf(
                    band(0, hue = -2, chroma = -3, brightness = 4),
                    band(1, hue = -4, chroma = 6, brightness = 10),
                    band(2, hue = -6, chroma = -8, brightness = 8),
                    band(3, chroma = -18, brightness = 5),
                    band(4, chroma = -20, brightness = 4),
                    band(5, chroma = -15, brightness = 3),
                    band(6, chroma = -12),
                    band(7, chroma = -6, brightness = 3),
                ),
            ),
            preset(
                key = "documentary-mono-v1",
                internalName = "Documentary Mono",
                contrast = 18,
                highlights = -10,
                shadows = 4,
                whiteLevel = 8,
                blackLevel = -10,
                saturation = -100,
            ),
        )
    }

    fun nameResId(filterId: String): Int? = when (filterId) {
        all[0].id -> R.string.photo_filter_builtin_natural
        all[1].id -> R.string.photo_filter_builtin_warm_film
        all[2].id -> R.string.photo_filter_builtin_teal_cinema
        all[3].id -> R.string.photo_filter_builtin_soft_portrait
        all[4].id -> R.string.photo_filter_builtin_documentary_mono
        else -> null
    }

    private fun preset(
        key: String,
        internalName: String,
        contrast: Int,
        highlights: Int,
        shadows: Int,
        whiteLevel: Int,
        blackLevel: Int,
        saturation: Int,
        bands: List<Np3ColorBand> = NP3_COLOR_BAND_CENTERS.map { band(it) },
    ): Np3PhotoFilter {
        require(bands.size == NP3_COLOR_BAND_CENTERS.size)
        val identity = buildString {
            append(key)
            listOf(contrast, highlights, shadows, whiteLevel, blackLevel, saturation)
                .forEach { append('|').append(it) }
            bands.forEach { value ->
                append('|').append(value.centerDegrees)
                append(',').append(value.hue)
                append(',').append(value.chroma)
                append(',').append(value.brightness)
            }
        }
        return Np3PhotoFilter(
            id = MessageDigest.getInstance("SHA-256")
                .digest(identity.toByteArray(Charsets.UTF_8))
                .joinToString("") { byte ->
                    "%02x".format(Locale.ROOT, byte.toInt() and 0xff)
                },
            name = internalName,
            contrast = contrast,
            highlights = highlights,
            shadows = shadows,
            whiteLevel = whiteLevel,
            blackLevel = blackLevel,
            saturation = saturation,
            colorBands = bands,
        )
    }

    private fun band(
        index: Int,
        hue: Int = 0,
        chroma: Int = 0,
        brightness: Int = 0,
    ): Np3ColorBand = band(NP3_COLOR_BAND_CENTERS[index], hue, chroma, brightness)

    private fun band(
        centerDegrees: Float,
        hue: Int = 0,
        chroma: Int = 0,
        brightness: Int = 0,
    ) = Np3ColorBand(centerDegrees, hue, chroma, brightness)
}
