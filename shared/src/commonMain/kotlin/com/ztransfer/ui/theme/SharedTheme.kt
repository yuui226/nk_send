package com.ztransfer.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.Color

/** 主题模式：跟随系统 / 固定深色 / 固定浅色。持久化在设置里。 */
enum class ThemeMode { SYSTEM, DARK, LIGHT }

private val DarkColorScheme = darkColorScheme(
    primary = AccentBlue,
    secondary = AccentPurple,
    tertiary = StatusConnected,
    background = DarkBackground,
    surface = DarkSurface,
    surfaceVariant = DarkSurfaceVariant,
    onPrimary = DarkBackground,
    onSecondary = DarkBackground,
    onTertiary = DarkBackground,
    onBackground = DarkOnBackground,
    onSurface = DarkOnSurface,
    onSurfaceVariant = DarkOnSurfaceVariant,
    error = StatusError,
    onError = DarkBackground,
)

private val LightColorScheme = lightColorScheme(
    primary = LightAccentBlue,
    secondary = LightAccentPurple,
    tertiary = LightStatusConnected,
    background = LightBackground,
    surface = LightSurface,
    surfaceVariant = LightSurfaceVariant,
    onPrimary = Color.White,
    onSecondary = Color.White,
    onTertiary = Color.White,
    onBackground = LightOnBackground,
    onSurface = LightOnSurface,
    onSurfaceVariant = LightOnSurfaceVariant,
    error = LightStatusError,
    onError = Color.White,
)

@Composable
fun SharedZTransferTheme(
    themeMode: ThemeMode = ThemeMode.SYSTEM,
    skinPreset: SkinPreset = SkinPreset.FROSTED_GLASS,
    content: @Composable () -> Unit
) {
    val darkTheme = isZTransferDarkTheme(themeMode)
    val colorScheme = if (darkTheme) DarkColorScheme else LightColorScheme
    val appColors = skinAppColors(skinPreset, darkTheme)
    CompositionLocalProvider(
        LocalAppColors provides appColors,
    ) {
        MaterialTheme(
            colorScheme = colorScheme,
            typography = Typography,
            content = content
        )
    }
}

@Composable
fun isZTransferDarkTheme(mode: ThemeMode): Boolean = when (mode) {
    ThemeMode.SYSTEM -> isSystemInDarkTheme()
    ThemeMode.DARK -> true
    ThemeMode.LIGHT -> false
}
