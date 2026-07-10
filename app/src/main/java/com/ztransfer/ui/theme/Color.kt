package com.nikon.transfer.ui.theme

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

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
    val surface: Color,
    val surfaceVariant: Color,
    val onBackground: Color,
    val onSurfaceVariant: Color,
    val accentBlue: Color,
    val accentOrange: Color,
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
    /** 全屏遮罩（弹层背后压暗）。 */
    val scrim: Color,
    /** 缩略图未加载时的占位底色（深色=Surface；浅色需比背景再深半档，空格子才有存在感）。 */
    val thumbPlaceholder: Color,
    /** 卡片发丝描边：浅色下白卡浮在浅灰背景上需要 1px 定界；深色恒为透明（不改变原视觉）。 */
    val cardHairline: Color,
)

val DarkAppColors = AppColors(
    background = DarkBackground,
    surface = DarkSurface,
    surfaceVariant = DarkSurfaceVariant,
    onBackground = DarkOnBackground,
    onSurfaceVariant = DarkOnSurfaceVariant,
    accentBlue = AccentBlue,
    accentOrange = AccentOrange,
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
    scrim = Color.Black.copy(alpha = 0.4f),
    thumbPlaceholder = DarkSurface,
    cardHairline = Color.Transparent,
)

val LightAppColors = AppColors(
    background = LightBackground,
    surface = LightSurface,
    surfaceVariant = LightSurfaceVariant,
    onBackground = LightOnBackground,
    onSurfaceVariant = LightOnSurfaceVariant,
    accentBlue = LightAccentBlue,
    accentOrange = LightAccentOrange,
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
    scrim = Color.Black.copy(alpha = 0.32f),
    thumbPlaceholder = Color(0xFFE6E6EB),
    cardHairline = Color.Black.copy(alpha = 0.06f),
)

val LocalAppColors = staticCompositionLocalOf { DarkAppColors }

/** 页面取色入口：`AppTheme.colors.xxx`。 */
object AppTheme {
    val colors: AppColors
        @Composable
        @ReadOnlyComposable
        get() = LocalAppColors.current
}
