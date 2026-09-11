package com.ztransfer.ui.theme

import android.app.Activity
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

/** Android keeps window side effects and its existing texture adapter; palette/type live in shared. */
@Composable
fun ZTransferTheme(
    themeMode: ThemeMode = ThemeMode.SYSTEM,
    skinPreset: SkinPreset = SkinPreset.FROSTED_GLASS,
    content: @Composable () -> Unit,
) {
    val darkTheme = isZTransferDarkTheme(themeMode)
    val buttonTexturePalette = rememberButtonTexturePalette(skinPreset, darkTheme)
    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            window.statusBarColor = android.graphics.Color.TRANSPARENT
            window.navigationBarColor = android.graphics.Color.TRANSPARENT
            WindowCompat.getInsetsController(window, view).apply {
                isAppearanceLightStatusBars = !darkTheme
                isAppearanceLightNavigationBars = !darkTheme
            }
        }
    }
    CompositionLocalProvider(LocalButtonTexturePalette provides buttonTexturePalette) {
        SharedZTransferTheme(themeMode, skinPreset, content)
    }
}
