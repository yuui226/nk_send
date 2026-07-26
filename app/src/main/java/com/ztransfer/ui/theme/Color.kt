package com.ztransfer.ui.theme

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import com.ztransfer.R

/**
 * 皮肤预设枚举，每种皮肤对应一组 [AppColors]（深色 + 浅色各一套）。
 *
 * 皮肤只换"玻璃按钮"的材质——即 [AppColors] 里那 4 个 button* token
 * （外加 [SkinTexture] 里按皮肤生成的按钮纹理）。面板/弹窗/提示条读的是
 * glass* token，皮肤从不覆写它们；页面背景、卡片底、缩略图占位、文字与
 * 强调/状态色也一律沿用基础色板（[DarkAppColors] / [LightAppColors]），
 * 所以换皮肤只有按钮换材质，设置页、弹窗、照片和列表与默认主题完全一致。
 */
enum class SkinPreset(val displayNameResId: Int) {
    FROSTED_GLASS(R.string.skin_frosted_glass),
    LEATHER(R.string.skin_leather),
    WOOD(R.string.skin_wood)
}

// 深色主题配色
val DarkBackground = Color(0xFF121212)
val DarkSurface = Color(0xFF1E1E1E)
val DarkSurfaceVariant = Color(0xFF2D2D2D)
val DarkOnBackground = Color(0xFFE0E0E0)
val DarkOnSurface = Color(0xFFE0E0E0)
val DarkOnSurfaceVariant = Color(0xFFB0B0B0)

// 强调色（深色主题用亮色系，黑底上通透）
val AccentBlue = Color(0xFF4FC3F7)
val AccentOrange = Color(0xFFFFB74D)
val AccentYellow = Color(0xFFFFD54F)
val AccentPurple = Color(0xFFAB47BC)

// 状态色。全 App 唯一的"成功绿"与"错误红"——不再另设肉眼难辨的
// AccentGreen/AccentRed 变体，主题色与状态图标同源，语义色全局一致。
val StatusConnected = Color(0xFF4CAF50)
val StatusError = Color(0xFFF44336)
val StatusWaiting = Color(0xFF757575)

// 浅色主题配色（背景/浅灰家族对齐 iOS 系统灰，白卡在其上更清爽）
val LightBackground = Color(0xFFF2F2F7)
val LightSurface = Color(0xFFFFFFFF)
val LightSurfaceVariant = Color(0xFFE9E9EE)
val LightOnBackground = Color(0xFF1C1C1E)
val LightOnSurface = Color(0xFF1C1C1E)
val LightOnSurfaceVariant = Color(0xFF6E6E73)

// 浅色强调（深色主题的亮色系强调在白底上对比不足，同色系整体加深一档）
val LightAccentBlue = Color(0xFF0277BD)
val LightAccentOrange = Color(0xFFEF6C00)
val LightAccentYellow = Color(0xFFB77900)
val LightAccentPurple = Color(0xFF7B1FA2)
val LightStatusConnected = Color(0xFF2E7D32)
val LightStatusError = Color(0xFFD32F2F)
val LightStatusWaiting = Color(0xFF8E8E93)

/**
 * 全 App 的语义色板：普通表面/文字 + 强调/状态色 + 毛玻璃质感的一整套 token。
 * 页面一律经 [AppTheme.colors] 取色，深浅切换只换这一个对象。
 * 毛玻璃相关 token 已把透明度烘焙进颜色里（深浅两套的合适透明度并不相同）。
 */
@Immutable
data class AppColors(
    val background: Color,
    /** 页面背景纵向微渐变（顶部略亮→底部略暗）：替代纯平底色，给页面一点纵深。
     *  [background] 仍是名义底色（取中间值），供叠层/渐变遮罩等继续引用。 */
    val backgroundTop: Color,
    val backgroundBottom: Color,
    val surface: Color,
    val surfaceVariant: Color,
    val onBackground: Color,
    val onSurfaceVariant: Color,
    val accentBlue: Color,
    val accentOrange: Color,
    val accentYellow: Color,
    val accentPurple: Color,
    val statusConnected: Color,
    val statusError: Color,
    val statusWaiting: Color,
    /** 强调色底上的前景（选中格文字、类型角标文字等）。 */
    val onAccent: Color,
    /** 毛玻璃悬浮控件底色（GlassButton / 队列胶囊）。 */
    val glassSurface: Color,
    /** 毛玻璃面板/提示条底色（高不透明度，保证可读）。 */
    val glassSurfaceHeavy: Color,
    /** 毛玻璃高光渐变（自上而下，上亮下淡）。 */
    val glassHighlightTop: Color,
    val glassHighlightBottom: Color,
    /** 毛玻璃描边渐变（上亮下暗的立体边）。 */
    val glassBorderTop: Color,
    val glassBorderBottom: Color,
    /** 面板/提示条的均匀细描边。 */
    val glassPanelBorder: Color,
    /** 面板顶部自上而下淡出的高光叠层。 */
    val glassSheen: Color,
    // ---- 按钮专属材质 token：皮肤（皮革/木纹）只覆写下面这 4 个字段 ----
    // GlassButton 读 button*，面板/弹窗/提示条读 glass*，因此换皮肤只换按钮，
    // 面板在三款皮肤下逐字节一致。默认皮肤下 button* 与对应的 glass* 同值。
    /** 玻璃按钮底色（非 panel 变体的基底填充）。 */
    val buttonSurface: Color,
    /** 玻璃按钮高光渐变（自上而下，上亮下淡）。 */
    val buttonHighlightTop: Color,
    val buttonHighlightBottom: Color,
    /** panel 变体按钮的顶部高光叠层（对应面板的 glassSheen）。 */
    val buttonSheen: Color,
    /** 全屏遮罩（弹层背后压暗）。 */
    val scrim: Color,
    /** 缩略图未加载时的占位底色（深色=Surface；浅色需比背景再深半档，空格子才有存在感）。 */
    val thumbPlaceholder: Color,
    /** 卡片发丝描边：浅色下白卡浮在浅灰背景上需要 1px 定界；深色恒为透明（不改变原视觉）。 */
    val cardHairline: Color,
)

val DarkAppColors = AppColors(
    background = DarkBackground,
    backgroundTop = Color(0xFF181818),
    backgroundBottom = Color(0xFF0D0D0D),
    surface = DarkSurface,
    surfaceVariant = DarkSurfaceVariant,
    onBackground = DarkOnBackground,
    onSurfaceVariant = DarkOnSurfaceVariant,
    accentBlue = AccentBlue,
    accentOrange = AccentOrange,
    accentYellow = AccentYellow,
    accentPurple = AccentPurple,
    statusConnected = StatusConnected,
    statusError = StatusError,
    statusWaiting = StatusWaiting,
    onAccent = DarkBackground,
    glassSurface = DarkSurface.copy(alpha = 0.45f),
    glassSurfaceHeavy = DarkSurface.copy(alpha = 0.92f),
    glassHighlightTop = Color.White.copy(alpha = 0.16f),
    glassHighlightBottom = Color.White.copy(alpha = 0.04f),
    glassBorderTop = Color.White.copy(alpha = 0.4f),
    glassBorderBottom = Color.White.copy(alpha = 0.1f),
    glassPanelBorder = Color.White.copy(alpha = 0.15f),
    glassSheen = Color.White.copy(alpha = 0.08f),
    // 按钮 token 与 glass token 同值：默认皮肤下按钮视觉与拆分前逐字节一致。
    buttonSurface = DarkSurface.copy(alpha = 0.45f),
    buttonHighlightTop = Color.White.copy(alpha = 0.16f),
    buttonHighlightBottom = Color.White.copy(alpha = 0.04f),
    buttonSheen = Color.White.copy(alpha = 0.08f),
    scrim = Color.Black.copy(alpha = 0.4f),
    thumbPlaceholder = DarkSurface,
    cardHairline = Color.Transparent,
)

val LightAppColors = AppColors(
    background = LightBackground,
    backgroundTop = Color(0xFFF8F8FB),
    backgroundBottom = Color(0xFFEBEBF1),
    surface = LightSurface,
    surfaceVariant = LightSurfaceVariant,
    onBackground = LightOnBackground,
    onSurfaceVariant = LightOnSurfaceVariant,
    accentBlue = LightAccentBlue,
    accentOrange = LightAccentOrange,
    accentYellow = LightAccentYellow,
    accentPurple = LightAccentPurple,
    statusConnected = LightStatusConnected,
    statusError = LightStatusError,
    statusWaiting = LightStatusWaiting,
    onAccent = Color.White,
    // 浅色毛玻璃 = 白色半透明底 + 顶部白色锐边 + 底部淡淡的暗边，白底上依然有"浮起"层次。
    // 底不透明度明显高于深色版：一是玻璃后面常是照片，太透内容发花；二是 Surface 的投影
    // 画在半透明表面之下，透出来会在按钮内部形成灰渍（浅色圆形 FAB 上尤其明显），
    // 0.85 让透出的阴影几乎不可见、又保留一点透底的玻璃感。
    glassSurface = Color.White.copy(alpha = 0.85f),
    glassSurfaceHeavy = Color.White.copy(alpha = 0.95f),
    glassHighlightTop = Color.White.copy(alpha = 0.60f),
    glassHighlightBottom = Color.White.copy(alpha = 0.10f),
    glassBorderTop = Color.White.copy(alpha = 0.95f),
    glassBorderBottom = Color.Black.copy(alpha = 0.08f),
    glassPanelBorder = Color.Black.copy(alpha = 0.10f),
    glassSheen = Color.White.copy(alpha = 0.55f),
    // 按钮 token 与 glass token 同值：默认皮肤下按钮视觉与拆分前逐字节一致。
    buttonSurface = Color.White.copy(alpha = 0.85f),
    buttonHighlightTop = Color.White.copy(alpha = 0.60f),
    buttonHighlightBottom = Color.White.copy(alpha = 0.10f),
    buttonSheen = Color.White.copy(alpha = 0.55f),
    scrim = Color.Black.copy(alpha = 0.32f),
    thumbPlaceholder = Color(0xFFE6E6EB),
    cardHairline = Color.Black.copy(alpha = 0.06f),
)

/**
 * 皮肤分发函数：根据选中的 [SkinPreset] 与当前深/浅模式返回对应的 [AppColors] 实例。
 * FROSTED_GLASS 即基础色板本身，另两款皮肤都是从基础色板 `copy()` 出来、
 * 只改 4 个 button* token，其余字段（含全部 glass* token）与基础色板逐字节一致。
 */
fun skinAppColors(skin: SkinPreset, dark: Boolean): AppColors = when (skin) {
    SkinPreset.FROSTED_GLASS -> if (dark) DarkAppColors else LightAppColors
    SkinPreset.LEATHER -> if (dark) DarkLeatherColors else LightLeatherColors
    SkinPreset.WOOD -> if (dark) DarkWoodColors else LightWoodColors
}

val LocalAppColors = staticCompositionLocalOf { DarkAppColors }

/** 页面取色入口：`AppTheme.colors.xxx`。 */
object AppTheme {
    val colors: AppColors
        @Composable
        @ReadOnlyComposable
        get() = LocalAppColors.current
}

/**
 * 页面背景渐变刷（[AppColors.backgroundTop] → [AppColors.backgroundBottom]）。
 * Scaffold 底与"需要不透明根"的页面（列表/队列页，转场层叠不透底）共用同一渐变，
 * 保证各页背景纵深一致。
 */
@Composable
fun rememberAppBackgroundBrush(): Brush {
    val colors = AppTheme.colors
    return remember(colors) {
        Brush.verticalGradient(listOf(colors.backgroundTop, colors.backgroundBottom))
    }
}

// ================================================================================================
// 皮肤系统：材质 token
//
// 皮肤只改 [AppColors] 里那 4 个 button* token，其余字段全部由 `copy()` 从基础色板继承。
// glass* token（面板/弹窗/提示条在读）刻意不覆写——设置卡片、弹层、提示条在三款皮肤下
// 逐字节一致，换皮肤只换按钮的材质；background/surface/文字/强调色同理不受影响。
// 皮革/木纹按钮另有一层程序化纹理（见 SkinTexture.kt），由 GlassButton 独家叠加。
//
// 两款材质沿两个轴与默认毛玻璃拉开差异（数值对着 GlassButton 的叠层顺序看：
// 底色 → 纹理 → 纵向高光渐变）：
//
//   1) 底色不透明度（透出多少背景）：毛玻璃 < 木纹 < 皮革
//      毛玻璃 0.45/0.85（深/浅），木纹 0.62/0.89，皮革 0.82/0.94。
//   2) 高光对比（多亮）：皮革（哑光） < 木纹（半光/缎面） < 毛玻璃（高光）
//      皮革高光压到毛玻璃的 1/3、sheen 几乎归零——皮革一旦发亮就像塑料。
// ================================================================================================

// 皮革材质色：暖而低饱和的棕（深色底）+ 暖奶油（高光）。
private val LeatherHideDark = Color(0xFF2C231A)
private val LeatherTanLight = Color(0xFFE8DAC2)
private val LeatherCream = Color(0xFFEFE0C8)
private val LeatherCreamLight = Color(0xFFFFF3E2)

// 木纹材质色：琥珀/蜜色，比皮革再饱和一档，高光偏暖金。
private val WoodAmberDark = Color(0xFF33270F)
private val WoodHoneyLight = Color(0xFFF0DFB8)
private val WoodGold = Color(0xFFFFE1A6)
private val WoodGoldLight = Color(0xFFFFF6DC)

// ================================================================================================
// 皮肤系统：皮革 (LEATHER) — 暖棕、最不透、哑光（只覆写按钮 token）
// ================================================================================================

/**
 * 皮革·深色：按钮是一整块暖棕硬皮。底色不透明度最高（0.82），按钮后面的内容基本被挡住，
 * 手感上是"实心的一张皮"而不是一层玻璃。
 * 高光只留 0.06（毛玻璃是 0.16）——光只在上沿擦一下，把哑光的"厚"做出来。
 */
val DarkLeatherColors = DarkAppColors.copy(
    buttonSurface = LeatherHideDark.copy(alpha = 0.82f),
    buttonHighlightTop = LeatherCream.copy(alpha = 0.06f),
    buttonHighlightBottom = LeatherCream.copy(alpha = 0.015f),
    buttonSheen = LeatherCream.copy(alpha = 0.025f),
)

/**
 * 皮革·浅色：浅褐/羊皮纸色按钮。浅色页面上放深棕按钮会压得过重，所以改成高不透明度的淡棕，
 * 与 [LightOnBackground] (#1C1C1E) 对比约 12:1，文字依然清楚。
 * 顶部高光只有毛玻璃版的一半（0.30 vs 0.60）、sheen 0.20 vs 0.55，缎光被抹掉。
 */
val LightLeatherColors = LightAppColors.copy(
    buttonSurface = LeatherTanLight.copy(alpha = 0.94f),
    buttonHighlightTop = LeatherCreamLight.copy(alpha = 0.30f),
    buttonHighlightBottom = LeatherCreamLight.copy(alpha = 0.05f),
    buttonSheen = LeatherCreamLight.copy(alpha = 0.20f),
)

// ================================================================================================
// 皮肤系统：木纹 (WOOD) — 琥珀/蜜色，半透，缎面半光（只覆写按钮 token）
// ================================================================================================

/**
 * 木纹·深色：琥珀深木按钮。底色 0.62 介于毛玻璃 0.45 与皮革 0.82 之间——木头是实心的，
 * 但这里只是一层薄板，还透一点底。
 * 高光取毛玻璃与皮革的中间值（0.11），呈缎面而非镜面；sheen 0.055 是一层淡淡的木蜡光。
 */
val DarkWoodColors = DarkAppColors.copy(
    buttonSurface = WoodAmberDark.copy(alpha = 0.62f),
    buttonHighlightTop = WoodGold.copy(alpha = 0.11f),
    buttonHighlightBottom = WoodGold.copy(alpha = 0.03f),
    buttonSheen = WoodGold.copy(alpha = 0.055f),
)

/**
 * 木纹·浅色：淡蜜色浅木按钮。比浅色皮革略透（0.89 vs 0.94）、略黄一点，
 * 与 [LightOnBackground] 对比约 13:1。
 * 高光 0.44、sheen 0.38，都落在毛玻璃（0.60 / 0.55）与皮革（0.30 / 0.20）之间。
 */
val LightWoodColors = LightAppColors.copy(
    buttonSurface = WoodHoneyLight.copy(alpha = 0.89f),
    buttonHighlightTop = WoodGoldLight.copy(alpha = 0.44f),
    buttonHighlightBottom = WoodGoldLight.copy(alpha = 0.07f),
    buttonSheen = WoodGoldLight.copy(alpha = 0.38f),
)
