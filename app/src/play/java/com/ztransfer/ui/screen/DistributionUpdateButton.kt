package com.ztransfer.ui.screen

import androidx.compose.runtime.Composable

/** Play 版不显示 APK 自更新入口。 */
@Composable
internal fun DistributionUpdateButton(
    cameraUsesWifi: Boolean,
    onHint: (String) -> Unit
) = Unit
