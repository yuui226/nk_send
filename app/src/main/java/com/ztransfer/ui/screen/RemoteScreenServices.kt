package com.ztransfer.ui.screen

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.ClipboardManager
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import com.ztransfer.ui.util.Haptics
import com.ztransfer.ui.util.rememberHaptics
import kotlinx.coroutines.CoroutineScope

/** One capture for screen services keeps the large monitor callbacks' argument lists smaller. */
@Stable
internal class RemoteScreenServices(
    val context: Context,
    val scope: CoroutineScope,
    val clipboard: ClipboardManager,
    val haptics: Haptics,
)

@Composable
internal fun rememberRemoteScreenServices(hapticsEnabled: Boolean): RemoteScreenServices {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboardManager.current
    val haptics = rememberHaptics(hapticsEnabled)
    return remember(context, scope, clipboard, haptics) {
        RemoteScreenServices(context, scope, clipboard, haptics)
    }
}
