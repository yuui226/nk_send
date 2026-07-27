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
    internal val skin: SkinPreset,
    private val dark: Boolean
) {
    private val brushes = arrayOfNulls<Brush>(TEXTURE_VARIANTS)

    fun brushFor(seed: Int): Brush {
        val variantCount = if (skin == SkinPreset.FROSTED_GLASS) FROST_TEXTURE_VARIANTS
        else TEXTURE_VARIANTS
        val variant = Math.floorMod(mixSeed(seed), variantCount)
        return brushes[variant] ?: ShaderBrush(
            ImageShader(
                image = buttonTextureTile(skin, dark, variant),
                tileModeX = TileMode.Repeated,
                tileModeY = TileMode.Repeated
            )
        ).also { brushes[variant] = it }
    }
}

/** 三种按钮材质都在这里提供稳定纹理；毛玻璃使用更轻的微霜噪点。 */
val LocalButtonTexturePalette = staticCompositionLocalOf<ButtonTexturePalette?> { null }

/**
 * 皮革/木纹使用 8 个、微霜使用 4 个确定性变体。纹理只在变体第一次被按钮选中时生成，
 * 之后进程级缓存；
 * 避免切换主题时一次性生成整套纹理造成卡顿。
 */
@Composable
fun rememberButtonTexturePalette(
    skin: SkinPreset,
    dark: Boolean
): ButtonTexturePalette? = remember(skin, dark) {
    ButtonTexturePalette(skin, dark)
}

private const val TILE = 128
private const val FROST_TILE = 96
private const val TEXTURE_VARIANTS = 8
private const val FROST_TEXTURE_VARIANTS = 4
private const val TAU = (2 * PI).toFloat()

/** 皮革/木纹各 8 张 128px，微霜各 4 张 96px；全部缓存仍低于 2.5 MiB。 */
private val tileCache = HashMap<Int, ImageBitmap>()

private fun buttonTextureTile(
    skin: SkinPreset,
    dark: Boolean,
    variant: Int
): ImageBitmap {
    val key = (skin.ordinal * 2 + if (dark) 1 else 0) * TEXTURE_VARIANTS + variant
    return tileCache.getOrPut(key) {
        val seed = mixSeed(0x5F3759DF xor (skin.ordinal * 0x45D9F3B) xor variant)
        val tileSize = if (skin == SkinPreset.FROSTED_GLASS) FROST_TILE else TILE
        val pixels = when (skin) {
            SkinPreset.FROSTED_GLASS -> frostedGlassTilePixels(dark, seed, tileSize)
            SkinPreset.LEATHER -> leatherTilePixels(dark, seed)
            SkinPreset.WOOD -> woodTilePixels(dark, seed)
        }
        Bitmap.createBitmap(pixels, tileSize, tileSize, Bitmap.Config.ARGB_8888).asImageBitmap()
    }
}

// =================================================================================================
// 毛玻璃：低频雾化起伏 + 中频冰晶散射 + 极细颗粒。
// 只生成透明明暗扰动，不画闭合边缘；按钮的体积光与交互高光由 GlassButton 实时绘制。
// =================================================================================================

private fun frostedGlassTilePixels(dark: Boolean, seed: Int, tileSize: Int): IntArray {
    val out = IntArray(tileSize * tileSize)
    val maxAlpha = if (dark) 0.105f else 0.072f
    val lightRgb = if (dark) 0xE8FAFF else 0xFFFFFF
    val darkRgb = if (dark) 0x07131C else 0x708090

    for (y in 0 until tileSize) {
        val v = y.toFloat() / tileSize
        for (x in 0 until tileSize) {
            val u = x.toFloat() / tileSize
            val macro = periodicValueNoise(u, v, 3, 3, seed + 101)
            val mist = periodicValueNoise(
                u + macro * 0.018f,
                v - macro * 0.014f,
                11,
                9,
                seed + 211
            )
            val crystal = periodicValueNoise(
                u - mist * 0.012f,
                v + mist * 0.012f,
                29,
                31,
                seed + 307
            )
            val grain = cellHash(x, y, seed + 401) * 2f - 1f

            // 宏观雾感必须非常轻，主要由细小明暗散射打破塑料般的纯渐变。
            val texture = 0.16f * macro +
                0.28f * mist +
                0.32f * crystal +
                0.16f * grain
            out[y * tileSize + x] = packSigned(texture, maxAlpha, lightRgb, darkRgb)
        }
    }
    return out
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
// 木纹：非对称年轮 + 多尺度 domain warp + 顺纹纤维 + 细导管 + 少量柔和木结。
// 主纹沿按钮长边延伸；各频率均为整数，配合周期噪声保持 128px tile 无缝。
// =================================================================================================

private fun woodTilePixels(dark: Boolean, seed: Int): IntArray {
    val out = IntArray(TILE * TILE)
    val maxAlpha = if (dark) 0.30f else 0.21f
    val lightRgb = if (dark) 0xE0B16E else 0xF6D59A
    val darkRgb = if (dark) 0x160B05 else 0x5C3013
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

            // 少数变体带一个淡木结。环面距离让木结靠近 tile 边缘时仍能无缝接续。
            val knotDx = torusDelta(u, knotX)
            val knotDy = torusDelta(v, knotY)
            val knotDistance = sqrt(
                (knotDx / 0.17f) * (knotDx / 0.17f) +
                    (knotDy / 0.25f) * (knotDy / 0.25f)
            )
            val knotMask = if (knotEnabled) exp(-2.7f * knotDistance * knotDistance) else 0f
            val knotWarp = knotMask * 0.48f *
                sin(TAU * (u - knotX + periodicValueNoise(u, v, 3, 3, seed + 307)))
            val knotCore = if (knotEnabled) exp(-10f * knotDistance * knotDistance) else 0f
            val knotRing = knotMask * sin(TAU * (3.4f * knotDistance + 0.15f * mid))

            // 年轮保持 5 个完整周期；两级柔和晚材线比硬阈值更像真实生长层。
            val ringCoordinate = 5f * (v + bend) +
                0.20f * sin(TAU * (u + phase)) + knotWarp
            val ringCycle = fract(ringCoordinate)
            val lateWoodCenter = 0.79f + 0.045f * mid
            val lateWoodDistance = (ringCycle - lateWoodCenter) / 0.075f
            val lateWood = exp(-lateWoodDistance * lateWoodDistance)
            val lateWoodShoulder = exp(
                -((ringCycle - lateWoodCenter + 0.105f) / 0.14f) *
                    ((ringCycle - lateWoodCenter + 0.105f) / 0.14f)
            )
            val earlyWood = cos(TAU * ringCycle)

            // 高频纤维沿长边走，宽窄不一，避免只剩下几条规则粗波浪。
            val fiberWarp = periodicValueNoise(u, v, 9, 7, seed + 401)
            val fiber = sin(TAU * (27f * v + 0.55f * fiberWarp + bend * 4f))
            val fineCoordinate = 17f * (v + 0.55f * bend) + 0.38f * fiberWarp
            val fineCycle = fract(fineCoordinate)
            val fineDistance = (fineCycle - 0.82f) / 0.07f
            val fineLine = exp(-fineDistance * fineDistance)
            val fiberMask = 0.55f + 0.45f *
                periodicValueNoise(u, v, 7, 3, seed + 503).coerceIn(-0.8f, 0.8f)
            val macroTone = periodicValueNoise(u, v, 3, 2, seed + 601)

            // 椭圆形细导管沿木纹方向拉长，只画实心暗痕，不画孔洞外圈。
            val vesselGridX = u * 12f
            val vesselGridY = v * 26f
            val vesselCellX = floor(vesselGridX).toInt()
            val vesselCellY = floor(vesselGridY).toInt()
            val vesselLocalX = fract(vesselGridX)
            val vesselLocalY = fract(vesselGridY)
            val vesselHash = cellHash(vesselCellX, vesselCellY, seed + 719)
            val vesselCenterX = 0.18f + 0.64f *
                cellHash(vesselCellX, vesselCellY, seed + 761)
            val vesselCenterY = 0.20f + 0.60f *
                cellHash(vesselCellX, vesselCellY, seed + 809)
            val vesselDx = (vesselLocalX - vesselCenterX) / 0.34f
            val vesselDy = (vesselLocalY - vesselCenterY) / 0.09f
            val vessel = if (vesselHash > 0.72f) {
                exp(-3.2f * (vesselDx * vesselDx + vesselDy * vesselDy)) *
                    smoothStep(0.72f, 0.96f, vesselHash)
            } else {
                0f
            }

            val texture = 0.16f * macroTone +
                0.14f * earlyWood -
                0.72f * lateWood -
                0.12f * lateWoodShoulder -
                0.12f * fineLine * fiberMask +
                0.045f * fiber -
                0.18f * vessel -
                0.24f * knotCore +
                0.08f * knotRing
            out[y * TILE + x] = packSigned(texture, maxAlpha, lightRgb, darkRgb)
        }
    }
    return out
}

// =================================================================================================
// 皮革：先生成连续高度场，再根据固定柔光计算粒面法线明暗。
// 这样颗粒有真实的凸起与阴影，而不是把红色噪声直接贴在按钮上；不绘制任何单元外框。
// =================================================================================================

private fun leatherTilePixels(dark: Boolean, seed: Int): IntArray {
    val out = IntArray(TILE * TILE)
    val height = FloatArray(TILE * TILE)
    val pigment = FloatArray(TILE * TILE)
    val maxAlpha = if (dark) 0.35f else 0.25f
    val lightRgb = if (dark) 0xE2A08A else 0xF4BEA3
    val darkRgb = if (dark) 0x150605 else 0x512019
    val wrinkleDirection = if ((seed and 1) == 0) 1f else -1f

    // 第一遍只构造皮面高度。三种互不成格的颗粒尺度叠加后仍保持周期化，可无缝平铺。
    for (y in 0 until TILE) {
        val v = y.toFloat() / TILE
        for (x in 0 until TILE) {
            val u = x.toFloat() / TILE

            val warpU = 0.026f * periodicValueNoise(u, v, 3, 4, seed + 101)
            val warpV = 0.026f * periodicValueNoise(u, v, 4, 3, seed + 151)
            val broadGrain = periodicValueNoise(
                u + warpU,
                v + warpV,
                8,
                7,
                seed + 607
            )
            val pebble = periodicValueNoise(
                u - warpV,
                v + warpU,
                16,
                15,
                seed + 659
            )
            val fineGrain = periodicValueNoise(
                u + warpU * 0.45f,
                v - warpV * 0.45f,
                29,
                27,
                seed + 691
            )

            // 细皱直接压入高度场。低频遮罩把长线切断，避免规则的平行刻痕。
            val wrinkleWarp = periodicValueNoise(u, v, 4, 3, seed + 701)
            val wrinkleCarrier = abs(
                sin(TAU * (2f * u + wrinkleDirection * v + 0.42f * wrinkleWarp))
            )
            val wrinkleMask = smoothStep(
                0.48f,
                0.86f,
                periodicValueNoise(u, v, 2, 3, seed + 743)
            )
            val wrinkle = smoothStep(0.945f, 0.995f, wrinkleCarrier) * wrinkleMask
            height[y * TILE + x] =
                0.48f * broadGrain +
                0.36f * pebble +
                0.16f * fineGrain -
                0.24f * wrinkle
            pigment[y * TILE + x] =
                0.72f * periodicValueNoise(u, v, 2, 2, seed + 401) +
                0.28f * periodicValueNoise(u, v, 4, 5, seed + 503)
        }
    }

    // 第二遍用高度差近似法线。光从左上方掠过，每颗皮粒便自然产生一亮一暗的立体面。
    fun heightAt(x: Int, y: Int): Float {
        val wrappedX = Math.floorMod(x, TILE)
        val wrappedY = Math.floorMod(y, TILE)
        return height[wrappedY * TILE + wrappedX]
    }

    for (y in 0 until TILE) {
        for (x in 0 until TILE) {
            val center = heightAt(x, y)
            val slopeX = heightAt(x + 1, y) - heightAt(x - 1, y)
            val slopeY = heightAt(x, y + 1) - heightAt(x, y - 1)
            val neighborMean = (
                heightAt(x - 1, y) +
                    heightAt(x + 1, y) +
                    heightAt(x, y - 1) +
                    heightAt(x, y + 1)
                ) * 0.25f
            val normalLight = (-1.35f * slopeX - 1.05f * slopeY).coerceIn(-1f, 1f)
            val localRelief = (center - neighborMean).coerceIn(-0.35f, 0.35f)

            // 毛孔是极少量实心暗点；不画外沿高光，避免再次出现圆形框。
            val poreHash = cellHash(x, y, seed + 809)
            val pore = smoothStep(0.994f, 0.9996f, poreHash)
            val micro = cellHash(x, y, seed + 907) * 2f - 1f
            val texture =
                0.14f * pigment[y * TILE + x] +
                0.72f * normalLight +
                0.42f * localRelief -
                0.22f * pore +
                0.035f * micro
            out[y * TILE + x] = packSigned(texture, maxAlpha, lightRgb, darkRgb)
        }
    }
    return out
}
