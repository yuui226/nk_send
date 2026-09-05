package com.ztransfer.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import com.ztransfer.ui.theme.*

/** Same palette/theme/background as Android; UIKit system appearance remains the Swift shell's job. */
@Composable
internal fun NativeAppTheme(appearance: NativeAppearanceState, content: @Composable () -> Unit) {
    val palette = rememberButtonTexturePalette(appearance.skin, isZTransferDarkTheme(appearance.theme))
    CompositionLocalProvider(LocalButtonTexturePalette provides palette) {
        SharedZTransferTheme(appearance.theme, appearance.skin) {
            Box(Modifier.fillMaxSize().background(rememberAppBackgroundBrush())) { content() }
        }
    }
}
