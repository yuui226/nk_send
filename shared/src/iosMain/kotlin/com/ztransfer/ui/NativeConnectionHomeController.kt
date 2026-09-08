package com.ztransfer.ui

import androidx.compose.runtime.*
import androidx.compose.ui.window.ComposeUIViewController
import platform.UIKit.UIViewController

object NativeConnectionHomeController {
    fun create(model: NativeConnectionHomeModel, appearance: NativeAppearanceModel): UIViewController = ComposeUIViewController {
        val state by appearance.state.collectAsState()
        NativeAppTheme(state) { NativeConnectionHome(model, state.resolvedLanguage, appearance) }
    }
}
