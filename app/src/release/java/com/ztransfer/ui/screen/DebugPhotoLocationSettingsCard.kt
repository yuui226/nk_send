package com.ztransfer.ui.screen

import androidx.compose.runtime.Composable
import com.ztransfer.frame.PhotoFrameLocationOverride

/** Release build: no UI and no retained spacing. */
@Composable
internal fun DebugPhotoLocationSettingsCard(
    @Suppress("UNUSED_PARAMETER")
    onStateChanged: (
        enabled: Boolean,
        config: PhotoFrameLocationOverride?,
    ) -> Unit = { _, _ -> },
) = Unit
