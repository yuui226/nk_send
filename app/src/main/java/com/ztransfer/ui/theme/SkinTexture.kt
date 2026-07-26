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
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * 皮肤按钮纹理：运行时程序化生成的无缝平铺小图（128×128），叠在 GlassButton
 * 底色之上、高光渐变之下，让皮革/木纹看起来是真材质而不只是换个色调。
 *
 * 设计要点：
 *  - 不引入任何图片资源。图案全部由整数频率的周期函数（正弦/环面 Worley）构成，
 *    在两个轴向上天然首尾相接，TileMode.Repeated 平铺无缝。
 *  - 纹理强度（透明度）直接烘焙进 tile 像素里——绘制端一律按 1f alpha 平铺，
 *    调"纹理浓淡"只改本文件里的 maxAlpha 常量即可（深/浅模式各一档）。
 *  - 每个 (皮肤, 深浅) 组合只生成一次 tile，进程级缓存；ImageShader 平铺绘制
 *    本身是廉价操作，不存在每帧分配。
 *  - 只有 GlassButton 读 [LocalButtonTexture]——面板/弹窗不参与皮肤（见 Color.kt
 *    里 button 系与 glass 系 token 的拆分），因此永远不会长出纹理。
 */
val LocalButtonTexture = staticCompositionLocalOf<Brush?> { null }

/** tile 边长。128 在按钮尺度下足够细腻，生成成本（一次 16k 像素）可忽略。 */
private const val TILE = 128

/** 进程级 tile 缓存：key = 皮肤序号 × 2 + 深浅位。皮肤只有两款带纹理，最多 4 张小图。 */
private val tileCache = HashMap<Int, ImageBitmap>()

/**
 * 按当前皮肤与深浅模式返回按钮纹理画刷；毛玻璃皮肤无纹理，返回 null。
 * ZTransferTheme 调用后经 [LocalButtonTexture] 下发。
 */
@Composable
fun rememberButtonTextureBrush(skin: SkinPreset, dark: Boolean): Brush? = remember(skin, dark) {
    when (skin) {
        SkinPreset.FROSTED_GLASS -> null
        SkinPreset.LEATHER, SkinPreset.WOOD -> ShaderBrush(
            ImageShader(buttonTextureTile(skin, dark), TileMode.Repeated, TileMode.Repeated)
        )
    }
}

private fun buttonTextureTile(skin: SkinPreset, dark: Boolean): ImageBitmap {
    val key = skin.ordinal * 2 + if (dark) 1 else 0
    return tileCache.getOrPut(key) {
        val pixels = when (skin) {
            SkinPreset.WOOD -> woodTilePixels(dark)
            else -> leatherTilePixels(dark)
        }
        Bitmap.createBitmap(pixels, TILE, TILE, Bitmap.Config.ARGB_8888).asImageBitmap()
    }
}

private const val TAU = (2 * PI).toFloat()

/** 把带符号强度 t ∈ [-1,1] 打包成像素：正值取亮色、负值取暗色，|t|×maxAlpha 为透明度。 */
private fun packSigned(t: Float, maxAlpha: Float, lightRgb: Int, darkRgb: Int): Int {
    val v = t.coerceIn(-1f, 1f)
    val a = ((if (v >= 0f) v else -v) * maxAlpha * 255f + 0.5f).toInt().coerceIn(0, 255)
    val rgb = if (v >= 0f) lightRgb else darkRgb
    return (a shl 24) or (rgb and 0xFFFFFF)
}

// ================================================================================================
// 木纹：顺纹条痕。亮度随 y 方向的正弦起伏（条痕平行于按钮长边），相位叠加两三个
// 八度的周期扰动做出天然的波浪；再压上窄的深色纹线。所有频率都是整数 → 无缝。
// ================================================================================================

private fun woodTilePixels(dark: Boolean): IntArray {
    val out = IntArray(TILE * TILE)
    // 纹理浓淡总旋钮：目标是"材质感"，不是墙纸。浅色底更透光，压得更淡。
    val maxAlpha = if (dark) 0.35f else 0.22f
    // 深色皮肤：暖金提亮 + 近黑深棕压暗；浅色皮肤：奶油提亮 + 暖褐纹线。
    val lightRgb = if (dark) 0xFFE1A6 else 0xFFF6DC
    val darkRgb = if (dark) 0x140C02 else 0x7A5C28
    for (y in 0 until TILE) {
        val v = y.toFloat() / TILE
        for (x in 0 until TILE) {
            val u = x.toFloat() / TILE
            // 周期扰动（两轴整数频率的正弦积），让条痕带一点手工的歪斜
            val turb = 1.6f * sin(TAU * 2f * u + 1.1f) * cos(TAU * v + 0.7f) +
                0.8f * sin(TAU * 5f * u + 2.9f) * cos(TAU * 3f * v + 4.2f) +
                0.4f * sin(TAU * 9f * u + 0.5f) * cos(TAU * 7f * v + 2.0f)
            // 主纹：每 tile 6 条的顺纹起伏
            val grain = sin(TAU * 6f * v + turb)
            // 窄深色纹线：grain 谷底附近急剧变暗（幂次越高线越细）
            val half = (1f - grain) * 0.5f
            val line = half * half * half * half * half * half
            // 顺纹细噪：沿 x 的高频微颤，模拟木射线
            val fine = 0.25f * sin(TAU * 23f * u + 3f * turb) * sin(TAU * 2f * v + 1.3f)
            val t = 0.55f * grain + fine - 1.4f * line
            out[y * TILE + x] = packSigned(t, maxAlpha, lightRgb, darkRgb)
        }
    }
    return out
}

// ================================================================================================
// 皮革：细颗粒荔枝纹。环面（wrap-around）上的抖动网格 Worley 噪声——每个格子里
// 撒一个确定性伪随机特征点，像素取最近/次近距离：F2−F1 小的地方是细胞边界
// （压暗成皱缝），细胞中心微微鼓起提亮。距离在环面上计算，平铺无缝。
// ================================================================================================

/** 确定性整数哈希 → [0,1)。同一格子永远撒同一个点，纹理稳定可复现。 */
private fun cellHash(i: Int, j: Int, s: Int): Float {
    var h = i * 374761393 + j * 668265263 + s * 974711
    h = h xor (h ushr 13)
    h *= 1274126177
    h = h xor (h ushr 16)
    return (h and 0x7fffffff).toFloat() / 0x7fffffff
}

private fun leatherTilePixels(dark: Boolean): IntArray {
    val out = IntArray(TILE * TILE)
    // 纹理浓淡总旋钮（同木纹：浅色底压淡）。
    val maxAlpha = if (dark) 0.40f else 0.25f
    val lightRgb = if (dark) 0xEFE0C8 else 0xFFF8EC
    val darkRgb = if (dark) 0x120B05 else 0x6B5138
    val cells = 8                    // 8×8 格 → 单元约 16px，颗粒够细
    val cs = TILE.toFloat() / cells
    for (y in 0 until TILE) {
        val v = y.toFloat() / TILE
        for (x in 0 until TILE) {
            val u = x.toFloat() / TILE
            // 3×3 邻域找最近(F1)/次近(F2)特征点。哈希用取模后的格子号（环面周期），
            // 坐标用未取模的格子号（跨边界距离正确）——两者配合即无缝。
            var f1 = Float.MAX_VALUE
            var f2 = Float.MAX_VALUE
            val ci = (x / cs.toInt()).coerceAtMost(cells - 1)
            val cj = (y / cs.toInt()).coerceAtMost(cells - 1)
            for (dj in -1..1) {
                for (di in -1..1) {
                    val ni = ci + di
                    val nj = cj + dj
                    val wi = Math.floorMod(ni, cells)
                    val wj = Math.floorMod(nj, cells)
                    val fx = (ni + 0.2f + 0.6f * cellHash(wi, wj, 1)) * cs
                    val fy = (nj + 0.2f + 0.6f * cellHash(wi, wj, 2)) * cs
                    val dx = fx - x
                    val dy = fy - y
                    val d = sqrt(dx * dx + dy * dy)
                    if (d < f1) { f2 = f1; f1 = d } else if (d < f2) f2 = d
                }
            }
            // 皱缝：F2−F1 → 0 处是细胞分界，指数衰减聚成细暗缝
            val crevice = exp(-4f * (f2 - f1) / cs)
            // 鼓包：细胞中心（F1 小）微微提亮，做出哑光颗粒的受光面
            val dome = 1f - (f1 / (0.75f * cs)).coerceIn(0f, 1f)
            // 细噪：高频周期颤动，避免颗粒表面过于干净（整数频率 → 无缝）
            val fine = 0.12f * sin(TAU * 17f * u + 0.9f) * sin(TAU * 13f * v + 2.4f)
            val t = 0.35f * dome - crevice + fine
            out[y * TILE + x] = packSigned(t, maxAlpha, lightRgb, darkRgb)
        }
    }
    return out
}
