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
    TITANIUM(R.string.skin_titanium),
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
    // ---- 按钮专属材质 token：皮肤（钛合金/木纹）只覆写下面这 4 个字段 ----
    // GlassButton 读 button*，面板/弹窗/提示条读 glass*，因此换皮肤只换按钮，
    // 面板在三款皮肤下逐字节一致；默认毛玻璃按钮也可单独调出更轻、更透的光学质感。
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
    // 深色按钮是 40% 冷灰半透明磨砂；宽缓鹅卵石光场由 GlassButton 绘制。
    buttonSurface = Color(0xFF25313B).copy(alpha = 0.40f),
    buttonHighlightTop = Color.White.copy(alpha = 0.025f),
    buttonHighlightBottom = Color.Transparent,
    buttonSheen = Color.White.copy(alpha = 0.025f),
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
    // 浅色液态玻璃增加冷雾蓝密度与顶部散射：在浅灰页面上仍能明确看出一层磨砂玻璃，
    // 但保持半透明，不退化成不透明的白色塑料按钮。
    buttonSurface = Color(0xFFEAF4FA).copy(alpha = 0.86f),
    buttonHighlightTop = Color.White.copy(alpha = 0.12f),
    buttonHighlightBottom = Color(0xFFB8D5E5).copy(alpha = 0.025f),
    buttonSheen = Color.White.copy(alpha = 0.10f),
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
    SkinPreset.TITANIUM -> if (dark) DarkTitaniumColors else LightTitaniumColors
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
// 钛合金/木纹按钮另有一层程序化纹理（见 SkinTexture.kt），由 GlassButton 独家叠加。
//
// 两款材质沿两个轴与默认毛玻璃拉开差异（数值对着 GlassButton 的叠层顺序看：
// 底色 → 纹理 → 纵向高光渐变）：
//
//   1) 底色不透明度（透出多少背景）：毛玻璃 < 木纹 < 钛合金
//      毛玻璃 0.40/0.86（深/浅），木纹 0.86/0.96，钛合金两套均为 0.98。
//   2) 高光形态：钛合金是冷色宽反射，木纹是暖色硬质微弧，毛玻璃是柔和散射。
// ================================================================================================

// 钛合金材质色：深色石墨钛 / 浅色原钛银，均保持低饱和冷灰。
private val TitaniumGraphite = Color(0xFF68737A)
private val TitaniumSilver = Color(0xFFBBC3C8)
private val TitaniumHighlight = Color(0xFFEAF1F4)
private val TitaniumHighlightLight = Color(0xFFFAFCFD)
private val TitaniumShadow = Color(0xFF303A41)
private val TitaniumShadowLight = Color(0xFF68737B)

// 木纹材质色：胡桃棕 / 蜂蜜橡木，底色更实、高光为克制的木蜡缎光。
private val WoodAmberDark = Color(0xFF3F2818)
private val WoodHoneyLight = Color(0xFFC89554)
private val WoodGold = Color(0xFFD8A765)
private val WoodGoldLight = Color(0xFFF2CF93)

// ================================================================================================
// 皮肤系统：钛合金 (TITANIUM) — 冷灰金属、圆润宽反射（只覆写按钮 token）
// ================================================================================================

/**
 * 钛合金·深色：石墨钛基底几乎不透，宽冷光和深灰收边由 GlassButton 塑造成圆润金属块。
 */
val DarkTitaniumColors = DarkAppColors.copy(
    buttonSurface = TitaniumGraphite.copy(alpha = 0.98f),
    buttonHighlightTop = TitaniumHighlight.copy(alpha = 0.080f),
    buttonHighlightBottom = TitaniumShadow.copy(alpha = 0.035f),
    buttonSheen = TitaniumHighlight.copy(alpha = 0.070f),
)

/**
 * 钛合金·浅色：原钛银基底配低饱和冷灰阴影，不使用纯白铬面镜光。
 */
val LightTitaniumColors = LightAppColors.copy(
    buttonSurface = TitaniumSilver.copy(alpha = 0.98f),
    buttonHighlightTop = TitaniumHighlightLight.copy(alpha = 0.150f),
    buttonHighlightBottom = TitaniumShadowLight.copy(alpha = 0.035f),
    buttonSheen = TitaniumHighlightLight.copy(alpha = 0.120f),
)

// ================================================================================================
// 皮肤系统：木纹 (WOOD) — 胡桃/蜜色，实木感，克制缎光（只覆写按钮 token）
// ================================================================================================

/**
 * 木纹·深色：胡桃深木按钮。底色提高到 0.86，避免纹理像贴在透明玻璃上。
 * 高光只负责整体起伏，顺纹缎光由 GlassButton 的局部材质光场绘制。
 */
val DarkWoodColors = DarkAppColors.copy(
    buttonSurface = WoodAmberDark.copy(alpha = 0.86f),
    buttonHighlightTop = WoodGold.copy(alpha = 0.030f),
    buttonHighlightBottom = WoodGold.copy(alpha = 0.010f),
    buttonSheen = WoodGold.copy(alpha = 0.025f),
)

/**
 * 木纹·浅色：高不透明度的蜂蜜橡木按钮。使用宽阔缎光而不是镜面亮边。
 */
val LightWoodColors = LightAppColors.copy(
    buttonSurface = WoodHoneyLight.copy(alpha = 0.96f),
    buttonHighlightTop = WoodGoldLight.copy(alpha = 0.060f),
    buttonHighlightBottom = WoodGoldLight.copy(alpha = 0.015f),
    buttonSheen = WoodGoldLight.copy(alpha = 0.045f),
)
