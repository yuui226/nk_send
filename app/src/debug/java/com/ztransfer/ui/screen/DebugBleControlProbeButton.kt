package com.ztransfer.ui.screen

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.ztransfer.gps.NikonBleControlProbe
import com.ztransfer.ui.theme.AppTheme

private enum class BleProbeUiAction(val key: Int? = null) {
    READ, MENU, VERIFY_MENU, UP(8), DOWN(9), RIGHT(10), LEFT(11), OK(7),
}

/** Debug 专用的显式按键测试面板；关闭、切换连接状态或退后台都会停止控制。 */
@Composable
internal fun DebugBleControlProbeButton(
    allowed: Boolean,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val scope = rememberCoroutineScope()
    val colors = AppTheme.colors
    val clipboard = LocalClipboardManager.current
    var open by remember { mutableStateOf(false) }
    var permissionDenied by remember { mutableStateOf(false) }
    var pendingAction by remember { mutableStateOf<BleProbeUiAction?>(null) }
    // Connection changes stop control but retain this owner's diagnostics for inspection.
    val probe = remember(context, scope) {
        NikonBleControlProbe(context.applicationContext, scope)
    }
    val currentProbe by rememberUpdatedState(probe)
    val currentAllowed by rememberUpdatedState(allowed)
    val currentOpen by rememberUpdatedState(open)

    DisposableEffect(probe, lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) {
                pendingAction = null
                probe.stop()
            }
        }
        lifecycle.addObserver(observer)
        onDispose {
            lifecycle.removeObserver(observer)
            probe.close()
        }
    }
    LaunchedEffect(allowed) {
        if (!allowed) {
            pendingAction = null
            permissionDenied = false
            probe.stop()
        }
    }

    fun dispatch(action: BleProbeUiAction) {
        if (!currentAllowed || !currentOpen ||
            !lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
        ) return
        val owner = currentProbe
        val state = owner.state.value
        if (state.busy) return
        when (action) {
            BleProbeUiAction.READ -> owner.readCapabilities()
            BleProbeUiAction.MENU -> if (state.canTestMenu) owner.testMenu()
            BleProbeUiAction.VERIFY_MENU -> if (state.canVerifyMenu) owner.verifyUnadvertisedMenuOnce()
            else -> if (state.remoteActive && state.canNavigate) owner.pressKey(requireNotNull(action.key))
        }
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        val action = pendingAction
        pendingAction = null
        if (currentAllowed && currentOpen && action != null) {
            permissionDenied = !granted
            if (granted) dispatch(action)
        }
    }

    fun request(action: BleProbeUiAction) {
        if (!currentAllowed || !currentOpen || pendingAction != null) return
        permissionDenied = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            pendingAction = action
            permissionLauncher.launch(Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            dispatch(action)
        }
    }

    fun dismiss() {
        pendingAction = null
        open = false
        probe.stop()
    }

    TextButton(
        onClick = {
            permissionDenied = false
            open = true
        },
        modifier = modifier,
        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
    ) {
        Text(
            "蓝牙测试",
            color = colors.accentBlue,
            fontSize = 12.sp,
        )
    }

    if (open) {
        val state by probe.state.collectAsState()
        val idle = allowed && !state.busy && pendingAction == null
        val canNavigate = idle && state.remoteActive && state.canNavigate
        val maxHeight = LocalConfiguration.current.screenHeightDp.dp * 0.85f
        Dialog(onDismissRequest = ::dismiss) {
            Surface(
                modifier = Modifier.fillMaxWidth().heightIn(max = maxHeight),
                shape = RoundedCornerShape(20.dp),
                color = colors.glassSurfaceHeavy,
                border = BorderStroke(1.dp, colors.glassPanelBorder),
            ) {
                Column(Modifier.padding(horizontal = 18.dp, vertical = 12.dp)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Text(
                            "蓝牙测试",
                            modifier = Modifier.weight(1f),
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold,
                            color = colors.onBackground,
                        )
                        if (state.busy) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(16.dp),
                                strokeWidth = 2.dp,
                                color = colors.accentBlue,
                            )
                        }
                        TextButton(onClick = ::dismiss) {
                            Text("关闭", color = colors.onSurfaceVariant)
                        }
                    }
                    Column(
                        modifier = Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Text(
                            "先读取能力，再测试菜单。观察相机屏幕；方向键会操作当前菜单。",
                            color = colors.onSurfaceVariant,
                            fontSize = 13.sp,
                        )
                        Text(
                            text = if (permissionDenied) "请允许蓝牙权限" else state.summary.ifBlank { "未读取" },
                            color = if (permissionDenied) colors.statusError else colors.onBackground,
                            fontSize = 13.sp,
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            BleProbeActionButton(
                                label = "读取能力",
                                enabled = idle,
                                modifier = Modifier.weight(1f),
                                onClick = { request(BleProbeUiAction.READ) },
                            )
                            BleProbeActionButton(
                                label = "测试菜单",
                                enabled = idle && state.canTestMenu,
                                modifier = Modifier.weight(1f),
                                onClick = { request(BleProbeUiAction.MENU) },
                            )
                        }
                        if (state.canVerifyMenu) {
                            BleProbeActionButton(
                                label = "验证菜单键（一次）",
                                enabled = idle,
                                modifier = Modifier.fillMaxWidth(),
                                onClick = { request(BleProbeUiAction.VERIFY_MENU) },
                            )
                        }
                        Column(
                            modifier = Modifier.align(Alignment.CenterHorizontally),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            BleProbeDirectionButton("↑", "向上", canNavigate) { request(BleProbeUiAction.UP) }
                            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                BleProbeDirectionButton("←", "向左", canNavigate) { request(BleProbeUiAction.LEFT) }
                                BleProbeDirectionButton("确定", "确定", canNavigate) { request(BleProbeUiAction.OK) }
                                BleProbeDirectionButton("→", "向右", canNavigate) { request(BleProbeUiAction.RIGHT) }
                            }
                            BleProbeDirectionButton("↓", "向下", canNavigate) { request(BleProbeUiAction.DOWN) }
                        }
                        if (state.log.isNotBlank()) {
                            SelectionContainer {
                                Text(
                                    text = state.log,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .heightIn(max = 200.dp)
                                        .clip(RoundedCornerShape(10.dp))
                                        .background(colors.surfaceVariant.copy(alpha = 0.6f))
                                        .verticalScroll(rememberScrollState())
                                        .padding(10.dp),
                                    color = colors.onSurfaceVariant,
                                    fontFamily = FontFamily.Monospace,
                                    fontSize = 10.sp,
                                    lineHeight = 15.sp,
                                )
                            }
                        }
                    }
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        TextButton(
                            onClick = {
                                pendingAction = null
                                probe.stop()
                            },
                            enabled = state.connected || state.busy || state.remoteActive,
                        ) {
                            Text("断开", color = colors.accentOrange.copy(
                                alpha = if (state.connected || state.busy || state.remoteActive) 1f else 0.4f,
                            ))
                        }
                        TextButton(
                            onClick = { clipboard.setText(AnnotatedString(state.log)) },
                            enabled = state.log.isNotBlank(),
                        ) {
                            Text("复制日志", color = colors.accentBlue.copy(alpha = if (state.log.isNotBlank()) 1f else 0.4f))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun BleProbeActionButton(
    label: String,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    GlassButton(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.height(44.dp),
        shape = RoundedCornerShape(12.dp),
        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 6.dp),
    ) {
        Text(label, color = AppTheme.colors.accentBlue, fontSize = 13.sp)
    }
}

@Composable
private fun BleProbeDirectionButton(
    label: String,
    description: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    BleProbeActionButton(
        label = label,
        enabled = enabled,
        modifier = Modifier.width(58.dp).semantics { contentDescription = description },
        onClick = onClick,
    )
}
