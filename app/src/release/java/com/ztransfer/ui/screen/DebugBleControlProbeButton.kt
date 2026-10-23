package com.ztransfer.ui.screen

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

/** Release 不组合蓝牙协议测试入口，也不依赖 Debug 测试引擎。 */
@Composable
@Suppress("UNUSED_PARAMETER")
internal fun DebugBleControlProbeButton(
    allowed: Boolean,
    modifier: Modifier = Modifier,
) = Unit
