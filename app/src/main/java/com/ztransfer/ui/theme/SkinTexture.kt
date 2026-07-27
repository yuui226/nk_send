package com.ztransfer.ui.theme

import android.graphics.Bitmap
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.ImageShader
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.asImageBitmap
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * 按钮材质由一组稳定变体组成。每颗按钮根据自己的组合位置或调用方提供的种子选择一张，
 * 同一按钮在重组和动画期间不会跳纹，相邻按钮也不再从同一块纹理左上角开始绘制。
 */
class ButtonTexturePalette internal constructor(
    private val skin: SkinPreset,
    private val dark: Boolean
) {
    private val brushes = arrayOfNulls<Brush>(TEXTURE_VARIANTS)

    fun brushFor(seed: Int): Brush {
        val variant = Math.floorMod(mixSeed(seed), TEXTURE_VARIANTS)
        return brushes[variant] ?: ShaderBrush(
            ImageShader(
                image = buttonTextureTile(skin, dark, variant),
                tileModeX = TileMode.Repeated,
                tileModeY = TileMode.Repeated
            )
        ).also { brushes[variant] = it }
    }
}

/** 毛玻璃为 null；皮革和木纹由 [GlassButton][com.ztransfer.ui.screen.GlassButton] 消费。 */
val LocalButtonTexturePalette = staticCompositionLocalOf<ButtonTexturePalette?> { null }

/**
 * 皮革/木纹均使用 8 个确定性变体。纹理只在变体第一次被按钮选中时生成，之后进程级缓存；
 * 避免切换主题时一次性生成整套纹理造成卡顿。
 */
@Composable
fun rememberButtonTexturePalette(
    skin: SkinPreset,
    dark: Boolean
): ButtonTexturePalette? = remember(skin, dark) {
    when (skin) {
        SkinPreset.FROSTED_GLASS -> null
        SkinPreset.LEATHER, SkinPreset.WOOD -> ButtonTexturePalette(skin, dark)
    }
}

private const val TILE = 128
private const val TEXTURE_VARIANTS = 8
private const val TAU = (2 * PI).toFloat()

/** 最多 2 种材质 × 2 种明暗 × 8 个变体，共约 2 MiB ARGB 像素。 */
private val tileCache = HashMap<Int, ImageBitmap>()

private fun buttonTextureTile(
    skin: SkinPreset,
    dark: Boolean,
    variant: Int
): ImageBitmap {
    val key = (skin.ordinal * 2 + if (dark) 1 else 0) * TEXTURE_VARIANTS + variant
    return tileCache.getOrPut(key) {
        val seed = mixSeed(0x5F3759DF xor (skin.ordinal * 0x45D9F3B) xor variant)
        val pixels = when (skin) {
            SkinPreset.WOOD -> woodTilePixels(dark, seed)
            else -> leatherTilePixels(dark, seed)
        }
        Bitmap.createBitmap(pixels, TILE, TILE, Bitmap.Config.ARGB_8888).asImageBitmap()
    }
}

/** 把带符号强度打包为透明明/暗叠色；底色仍由主题的 buttonSurface 决定。 */
private fun packSigned(t: Float, maxAlpha: Float, lightRgb: Int, darkRgb: Int): Int {
    val v = t.coerceIn(-1f, 1f)
    val alpha = abs(v) * maxAlpha
    val a = (alpha * 255f + 0.5f).toInt().coerceIn(0, 255)
    val rgb = if (v >= 0f) lightRgb else darkRgb
    return (a shl 24) or (rgb and 0xFFFFFF)
}

private fun mixSeed(value: Int): Int {
    var x = value
    x = (x xor (x ushr 16)) * 0x7FEB352D
    x = (x xor (x ushr 15)) * 0x846CA68B.toInt()
    return x xor (x ushr 16)
}

/** 确定性整数哈希，返回 [0, 1)。 */
private fun cellHash(i: Int, j: Int, seed: Int): Float {
    var h = i * 374761393 + j * 668265263 + seed * 974711
    h = h xor (h ushr 13)
    h *= 1274126177
    h = h xor (h ushr 16)
    return (h and 0x7FFFFFFF).toFloat() / 0x7FFFFFFF
}

private fun smoothCurve(value: Float): Float = value * value * (3f - 2f * value)

private fun smoothStep(edge0: Float, edge1: Float, value: Float): Float {
    val x = ((value - edge0) / (edge1 - edge0)).coerceIn(0f, 1f)
    return smoothCurve(x)
}

private fun fract(value: Float): Float = value - floor(value)

/**
 * 周期 Value Noise。思路取自 Yui Kinomoto 的 MIT Procedural Grain Wood Shader，
 * 这里改写为 CPU/Kotlin 版本并扩展为任意整数网格，保证小图两轴无缝平铺。
 * https://godotshaders.com/shader/procedural-grain-wood-shader/
 */
private fun periodicValueNoise(
    u: Float,
    v: Float,
    cellsX: Int,
    cellsY: Int,
    seed: Int
): Float {
    val gx = u * cellsX
    val gy = v * cellsY
    val x0 = floor(gx).toInt()
    val y0 = floor(gy).toInt()
    val tx = smoothCurve(gx - floor(gx))
    val ty = smoothCurve(gy - floor(gy))

    fun sample(x: Int, y: Int): Float {
        val wrappedX = Math.floorMod(x, cellsX)
        val wrappedY = Math.floorMod(y, cellsY)
        return cellHash(wrappedX, wrappedY, seed) * 2f - 1f
    }

    val a = sample(x0, y0)
    val b = sample(x0 + 1, y0)
    val c = sample(x0, y0 + 1)
    val d = sample(x0 + 1, y0 + 1)
    val top = a + (b - a) * tx
    val bottom = c + (d - c) * tx
    return top + (bottom - top) * ty
}

private fun torusDelta(a: Float, b: Float): Float {
    val direct = abs(a - b)
    return min(direct, 1f - direct)
}

// =================================================================================================
// 木纹：非对称年轮 + 多尺度 domain warp + 顺纹纤维 + 少量柔和木结。
// 主纹沿按钮长边延伸；各频率均为整数，配合周期噪声保持 128px tile 无缝。
// =================================================================================================

private fun woodTilePixels(dark: Boolean, seed: Int): IntArray {
    val out = IntArray(TILE * TILE)
    val maxAlpha = if (dark) 0.34f else 0.23f
    val lightRgb = if (dark) 0xD7A45E else 0xFFE2AE
    val darkRgb = if (dark) 0x170B03 else 0x6A3515
    val phase = cellHash(seed, 11, seed + 31)
    val knotEnabled = Math.floorMod(seed, 3) == 0
    val knotX = 0.18f + 0.64f * cellHash(seed, 17, seed + 43)
    val knotY = 0.18f + 0.64f * cellHash(seed, 23, seed + 59)

    for (y in 0 until TILE) {
        val v = y.toFloat() / TILE
        for (x in 0 until TILE) {
            val u = x.toFloat() / TILE

            // 大尺度弯曲让纹线像天然板材，不再是等距正弦条纹。
            val low = periodicValueNoise(u, v, 2, 2, seed + 101)
            val mid = periodicValueNoise(u, v, 5, 4, seed + 211)
            val bend = 0.075f * low + 0.028f * mid +
                0.018f * sin(TAU * (u + phase)) * cos(TAU * v)

            // 少数变体带一个淡木结。使用环面距离，靠近 tile 边缘时仍能无缝接续。
            val knotDx = torusDelta(u, knotX)
            val knotDy = torusDelta(v, knotY)
            val knotDistance = sqrt(
                (knotDx / 0.17f) * (knotDx / 0.17f) +
                    (knotDy / 0.25f) * (knotDy / 0.25f)
            )
            val knotMask = if (knotEnabled) exp(-2.7f * knotDistance * knotDistance) else 0f
            val knotWarp = knotMask * 0.48f *
                sin(TAU * (u - knotX + periodicValueNoise(u, v, 3, 3, seed + 307)))

            // 年轮保持 5 个完整周期；高斯型晚材线比硬阈值更像自然生长层。
            val ringCoordinate = 5f * (v + bend) +
                0.20f * sin(TAU * (u + phase)) + knotWarp
            val ringCycle = fract(ringCoordinate)
            val lateWoodCenter = 0.79f + 0.045f * mid
            val lateWoodDistance = (ringCycle - lateWoodCenter) / 0.075f
            val lateWood = exp(-lateWoodDistance * lateWoodDistance)
            val earlyWood = cos(TAU * ringCycle)

            // 高频纤维仍沿长边走，另叠一组极细的深色导管线，避免只有五条粗波浪。
            val fiberWarp = periodicValueNoise(u, v, 9, 7, seed + 401)
            val fiber = sin(TAU * (27f * v + 0.55f * fiberWarp + bend * 4f))
            val fineCoordinate = 17f * (v + 0.55f * bend) + 0.38f * fiberWarp
            val fineCycle = fract(fineCoordinate)
            val fineDistance = (fineCycle - 0.82f) / 0.07f
            val fineLine = exp(-fineDistance * fineDistance)
            val fiberMask = 0.55f + 0.45f *
                periodicValueNoise(u, v, 7, 3, seed + 503).coerceIn(-0.8f, 0.8f)
            val macroTone = periodicValueNoise(u, v, 3, 2, seed + 601)
            val texture = 0.20f * macroTone +
                0.17f * earlyWood -
                0.88f * lateWood -
                0.14f * fineLine * fiberMask +
                0.055f * fiber
            out[y * TILE + x] = packSigned(texture, maxAlpha, lightRgb, darkRgb)
        }
    }
    return out
}

// =================================================================================================
// 皮革：经过 domain warp 的多尺度软颗粒 + 低频皮色斑驳 + 稀疏细皱 + 微毛孔。
// 不绘制 Voronoi 单元边界，避免按钮上出现明显的多边形或圆形闭合框。
// =================================================================================================

private fun leatherTilePixels(dark: Boolean, seed: Int): IntArray {
    val out = IntArray(TILE * TILE)
    val maxAlpha = if (dark) 0.38f else 0.28f
    val lightRgb = if (dark) 0xD88A72 else 0xF8C2AA
    val darkRgb = if (dark) 0x180706 else 0x64251D

    for (y in 0 until TILE) {
        val v = y.toFloat() / TILE
        for (x in 0 until TILE) {
            val u = x.toFloat() / TILE

            // 先扭曲采样坐标，打散各尺度噪声的方向性；噪声本身周期化，因此仍能无缝。
            val warpU = 0.032f * periodicValueNoise(u, v, 3, 4, seed + 101)
            val warpV = 0.032f * periodicValueNoise(u, v, 4, 3, seed + 151)
            val macroTone = 0.70f * periodicValueNoise(u, v, 2, 2, seed + 401) +
                0.30f * periodicValueNoise(u, v, 4, 5, seed + 503)

            // 两个互不成格的噪声尺度形成柔软皮纹，不会出现封闭的蜂窝边界。
            val pebble = 0.68f * periodicValueNoise(
                u + warpU,
                v + warpV,
                9,
                8,
                seed + 607
            ) + 0.32f * periodicValueNoise(
                u - warpV,
                v + warpU,
                17,
                15,
                seed + 659
            )

            // 少量不闭合的斜向细皱；毛孔只作为暗点，不画孔洞外圈。
            val wrinkleWarp = periodicValueNoise(u, v, 4, 3, seed + 701)
            val wrinkleCarrier = abs(sin(TAU * (2f * u + v + 0.38f * wrinkleWarp)))
            val wrinkleMask = smoothStep(
                0.35f,
                0.82f,
                periodicValueNoise(u, v, 2, 3, seed + 743)
            )
            val wrinkle = smoothStep(0.90f, 0.985f, wrinkleCarrier) * wrinkleMask
            val poreNoise = periodicValueNoise(u, v, 23, 19, seed + 809)
            val pore = smoothStep(0.64f, 0.92f, poreNoise)
            val micro = periodicValueNoise(u, v, 31, 29, seed + 907)

            val texture = 0.18f * macroTone +
                0.34f * pebble -
                0.08f * wrinkle -
                0.06f * pore +
                0.08f * micro
            out[y * TILE + x] = packSigned(texture, maxAlpha, lightRgb, darkRgb)
        }
    }
    return out
}
