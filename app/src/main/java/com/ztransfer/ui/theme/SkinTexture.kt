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
 * 天然材质由一组确定性变体组成。每颗按钮根据稳定组合位置或调用方提供的种子选择一张：
 * A 按钮每次都回到 A 的纹理，B 按钮每次都回到 B 的纹理，同时相邻按钮不再整齐复制。
 */
class ButtonTexturePalette internal constructor(
    internal val skin: SkinPreset,
    private val dark: Boolean
) {
    private val variantCount = when (skin) {
        SkinPreset.FROSTED_GLASS -> 0
        SkinPreset.TITANIUM -> TITANIUM_TEXTURE_VARIANTS
        SkinPreset.WOOD -> WOOD_TEXTURE_VARIANTS
        SkinPreset.CAMERA_CONTROLS -> CAMERA_CONTROL_TEXTURE_VARIANTS
    }
    private val brushes = arrayOfNulls<Brush>(variantCount)

    fun brushFor(seed: Int): Brush? {
        // 毛玻璃不能再使用矩形位图 tile：即使像素本身接近无缝，GPU 采样、缩放和
        // 离屏合成仍可能把 tile 边界显成按钮上的方框。毛玻璃颗粒和体积光统一交给
        // GlassButton 的矢量光场绘制；三种实体材质才使用位图纹理。
        if (skin == SkinPreset.FROSTED_GLASS) return null
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

/** 三种实体材质在这里提供稳定纹理；纯净毛玻璃不使用位图噪声。 */
val LocalButtonTexturePalette = staticCompositionLocalOf<ButtonTexturePalette?> { null }

/**
 * 钛合金使用 12 个、木纹使用 24 个、相机按键使用 4 个确定性变体。纹理只在变体第一次被按钮选中时生成，
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

private const val TILE = 256
private const val TITANIUM_TEXTURE_VARIANTS = 12
private const val WOOD_TEXTURE_VARIANTS = 24
private const val CAMERA_CONTROL_TEXTURE_VARIANTS = 4
private const val CACHE_VARIANT_STRIDE = WOOD_TEXTURE_VARIANTS
private const val TAU = (2 * PI).toFloat()

/**
 * 天然纹理扩大到 256px，减少高密度屏幕上短周期重复；仍按实际命中的变体懒生成，
 * 不会在切换皮肤时一次性分配整套缓存。
 */
private val tileCache = HashMap<Int, ImageBitmap>()

private fun buttonTextureTile(
    skin: SkinPreset,
    dark: Boolean,
    variant: Int
): ImageBitmap {
    val key = (skin.ordinal * 2 + if (dark) 1 else 0) * CACHE_VARIANT_STRIDE + variant
    return tileCache.getOrPut(key) {
        val seed = mixSeed(0x5F3759DF xor (skin.ordinal * 0x45D9F3B) xor variant)
        val pixels = when (skin) {
            SkinPreset.FROSTED_GLASS -> error("Pure frosted glass does not use a bitmap texture")
            SkinPreset.TITANIUM -> titaniumTilePixels(dark, seed)
            SkinPreset.WOOD -> woodTilePixels(dark, seed)
            SkinPreset.CAMERA_CONTROLS -> cameraControlTilePixels(dark, seed)
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
// 木纹：非对称年轮 + 多尺度 domain warp + 顺纹纤维 + 细导管 + 少量柔和木结。
// 主纹沿按钮长边延伸；各频率均为整数，配合周期噪声保持 128px tile 无缝。
// =================================================================================================

private fun woodTilePixels(dark: Boolean, seed: Int): IntArray {
    val out = IntArray(TILE * TILE)
    val maxAlpha = if (dark) 0.30f else 0.21f
    val lightRgb = if (dark) 0xE0B16E else 0xF6D59A
    val darkRgb = if (dark) 0x160B05 else 0x5C3013
    val phase = cellHash(seed, 11, seed + 31)
    val ringCount = 4 + (cellHash(seed, 29, seed + 71) * 3f).toInt()
    val fiberCount = 24 + (cellHash(seed, 31, seed + 83) * 8f).toInt()
    val fineCount = 14 + (cellHash(seed, 37, seed + 97) * 6f).toInt()
    val bendStrength = 0.060f + 0.025f * cellHash(seed, 41, seed + 109)
    val knotEnabled = cellHash(seed, 43, seed + 127) > 0.58f
    val knotX = 0.18f + 0.64f * cellHash(seed, 17, seed + 43)
    val knotY = 0.18f + 0.64f * cellHash(seed, 23, seed + 59)

    for (y in 0 until TILE) {
        val v = y.toFloat() / TILE
        for (x in 0 until TILE) {
            val u = x.toFloat() / TILE

            // 大尺度弯曲让纹线像天然板材，不再是等距正弦条纹。
            val low = periodicValueNoise(u, v, 2, 2, seed + 101)
            val mid = periodicValueNoise(u, v, 5, 4, seed + 211)
            val bend = bendStrength * low + 0.028f * mid +
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

            // 每个稳定变体使用 4~6 个完整年轮周期；整数周期继续保证上下无缝。
            val ringCoordinate = ringCount * (v + bend) +
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
            val fiber = sin(TAU * (fiberCount * v + 0.55f * fiberWarp + bend * 4f))
            val fineCoordinate = fineCount * (v + 0.55f * bend) + 0.38f * fiberWarp
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
// 钛合金：低对比喷砂微粒 + 沿长边延伸的极细拉丝。
// 纹理只提供金属表面的微观方向性，圆润体积和宽反射由 GlassButton 实时绘制。
// =================================================================================================

private fun titaniumTilePixels(dark: Boolean, seed: Int): IntArray {
    val out = IntArray(TILE * TILE)
    val maxAlpha = if (dark) 0.115f else 0.080f
    val lightRgb = if (dark) 0xDDE7EC else 0xFFFFFF
    val darkRgb = if (dark) 0x28333A else 0x69747B

    for (y in 0 until TILE) {
        val v = y.toFloat() / TILE
        for (x in 0 until TILE) {
            val u = x.toFloat() / TILE
            val macro = periodicValueNoise(u, v, 4, 4, seed + 101)
            val warp = periodicValueNoise(u, v, 3, 5, seed + 211)
            val brushed = periodicValueNoise(
                u + 0.012f * warp,
                v + 0.004f * macro,
                9,
                96,
                seed + 307
            )
            val fine = periodicValueNoise(u, v, 47, 61, seed + 401)
            val micro = cellHash(x, y, seed + 503) * 2f - 1f
            val hairline = sin(
                TAU * (
                    72f * v +
                        0.18f * macro +
                        0.04f * sin(TAU * u)
                    )
            )
            val texture =
                0.10f * macro +
                0.34f * brushed +
                0.20f * fine +
                0.18f * micro +
                0.06f * hairline
            out[y * TILE + x] = packSigned(texture, maxAlpha, lightRgb, darkRgb)
        }
    }
    return out
}

// =================================================================================================
// 相机实体按键：低反射注塑键帽的等向细颗粒与极少量微凹点。
// 纹理仅负责近看时不显得像纯色矢量块；键帽的弧面、窄边和键程由 GlassButton 绘制。
// =================================================================================================

private fun cameraControlTilePixels(dark: Boolean, seed: Int): IntArray {
    val out = IntArray(TILE * TILE)
    val maxAlpha = if (dark) 0.090f else 0.075f
    val lightRgb = if (dark) 0xAEB5B9 else 0xC5CBCF
    val darkRgb = 0x030405

    for (y in 0 until TILE) {
        val v = y.toFloat() / TILE
        for (x in 0 until TILE) {
            val u = x.toFloat() / TILE
            val macro = periodicValueNoise(u, v, 5, 5, seed + 101)
            val micro = cellHash(x, y, seed + 307) * 2f - 1f
            val pitNoise = cellHash(x, y, seed + 401)
            val pit = if (pitNoise > 0.985f) {
                smoothStep(0.985f, 1f, pitNoise)
            } else {
                0f
            }
            val texture = 0.14f * macro + 0.48f * micro - 0.42f * pit
            out[y * TILE + x] = packSigned(texture, maxAlpha, lightRgb, darkRgb)
        }
    }
    return out
}
