package com.ztransfer.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.ztransfer.connection.*
import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.protocol.PtpConstants
import com.ztransfer.ui.screen.*
import com.ztransfer.ui.theme.AppTheme
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** One platform session owner. No sockets, queue, profile store or permission authority in shared UI. */
interface NativeConnectionHomePlatform {
    /** Optional local photo-effects route; camera connection is not required. */
    fun canOpenPhotoEffects(): Boolean = false
    fun openPhotoEffects() {}
    fun readConnectionMode(): String?
    fun saveConnectionMode(stationMode: Boolean): Boolean
    fun resetConnectionModeAfterConfirmation(): Boolean = false
    fun connectCamera(address: String, stationMode: Boolean, allowPairing: Boolean, requestId: Long): Boolean
    fun cancelConnection(requestId: Long)
    fun disconnectCamera(requestId: Long)
    fun openCameraFiles()
    fun openTransferQueue()
    fun openNetworkSettings()
    fun discoverCameras()
    fun stopDiscovering()
    fun connectChoice(id: String, paired: Boolean, allowPairing: Boolean, requestId: Long): Boolean
    fun clearExpectedCamera()
    fun forgetCameraProfile(id: String): Boolean
    fun resetCameraHistory(): Boolean
    fun recoverCameraIdentity(): Boolean
    fun clearRecoveryRecord(completion: NativeQueueActionCompletion) { completion.complete(false) }
    fun diagnosticReport(): String = ""
    fun clearDiagnostics() {}
    fun shareDiagnostics(): Boolean = false
}

/** paired distinguishes profile rows from live service rows; only the platform pairing store grants trust. */
data class NativeStationChoice(val id: String, val title: String, val detail: String, val paired: Boolean)

internal data class NativeConnectionHomeState(
    val address: String = PtpConstants.CAMERA_IP,
    val stationMode: Boolean = false,
    val allowPairing: Boolean = false,
    val requestId: Long = 0,
    val phase: String = "idle",
    val message: String? = null,
    val choices: List<NativeStationChoice> = emptyList(),
    val searching: Boolean = false,
    val discoveryMessage: String? = null,
    val expectedCamera: String? = null,
    val attemptedChoice: String? = null,
    val preferencesUnavailable: Boolean = false,
    val recoveryNotice: String? = null,
    val recoveryRecord: NativeRecoveryRecord = NativeRecoveryRecord(),
    val clearingRecovery: Boolean = false,
) {
    val busy: Boolean get() = phase == "connecting" || phase == "closing" || phase == "ready"
    val ready: Boolean get() = phase == "ready"
    fun presentation() = HomeConnectionUiState(
        isConnectedToCamera = ready, connectionType = if (ready) CameraConnectionType.WIFI else null,
        wirelessMode = if (stationMode) WirelessMode.STA else WirelessMode.AP, isStaConnection = ready && stationMode,
        staConnectionStatus = when { !stationMode -> StaConnectionStatus.IDLE; phase == "connecting" -> StaConnectionStatus.CONNECTING
            phase == "failed" -> StaConnectionStatus.FAILED; else -> StaConnectionStatus.IDLE },
        staConnectionError = message.takeIf { stationMode && phase == "failed" }, usbConnectionError = null,
        wifiConnectionStatus = when { stationMode -> WifiConnectionStatus.IDLE; phase == "connecting" -> WifiConnectionStatus.PROBING
            phase == "failed" -> WifiConnectionStatus.FAILED; else -> WifiConnectionStatus.IDLE })
}

class NativeConnectionHomeModel(platform: NativeConnectionHomePlatform) {
    private var platform: NativeConnectionHomePlatform? = platform
    private var closed = false
    private var nextRequest = 1L
    private var retryChoice: NativeStationChoice? = null
    private var celebratedRequest: Long? = null
    private var recoveryRecordRevision = 0L
    private var recoveryRequest = 0L
    private val savedMode = platform?.readConnectionMode()
    private val mutableState = MutableStateFlow(NativeConnectionHomeState(
        stationMode = savedMode == "sta", preferencesUnavailable = savedMode !in setOf("ap", "sta")))
    internal val state = mutableState.asStateFlow()
    fun currentRequestId(): Long = mutableState.value.requestId
    fun isReady(): Boolean = mutableState.value.ready
    fun currentPhase(): String = mutableState.value.phase
    fun currentAddress(): String = mutableState.value.address
    fun canOpenPhotoEffects(): Boolean = !closed && platform?.canOpenPhotoEffects() == true
    fun openPhotoEffects() { if (!closed) platform?.openPhotoEffects() }
    fun publishRecoveryRecord(names: List<String>, completed: Int, unavailable: Boolean, truncated: Boolean) {
        if (closed) return
        recoveryRecordRevision++
        if (!closed) mutableState.value = mutableState.value.copy(
            recoveryRecord = NativeRecoveryRecord(names.take(500).map { it.take(255) }, completed.coerceAtLeast(0), unavailable, truncated))
    }
    internal fun clearRecoveryRecord() {
        val owner = platform ?: return
        if (closed || mutableState.value.busy || mutableState.value.clearingRecovery) return
        val request = ++recoveryRequest
        val revision = recoveryRecordRevision
        mutableState.value = mutableState.value.copy(clearingRecovery = true)
        owner.clearRecoveryRecord(object : NativeQueueActionCompletion {
            override fun complete(succeeded: Boolean) {
                if (closed || request != recoveryRequest || !mutableState.value.clearingRecovery) return
                mutableState.value = mutableState.value.copy(clearingRecovery = false,
                    recoveryRecord = if (revision != recoveryRecordRevision) mutableState.value.recoveryRecord
                    else if (succeeded) NativeRecoveryRecord() else mutableState.value.recoveryRecord.copy(unavailable = true))
            }
        })
    }

    fun publishRecoveryNotice(code: String) {
        if (!closed && code in setOf("background", "disconnected", "permissions"))
            mutableState.value = mutableState.value.copy(recoveryNotice = code)
    }

    internal fun editAddress(value: String) {
        if (!closed && !mutableState.value.busy) {
            retryChoice = null
            mutableState.value = mutableState.value.copy(address = value.take(512), attemptedChoice = null)
        }
    }
    internal fun resetApAddress() {
        if (!mutableState.value.stationMode) editAddress(PtpConstants.CAMERA_IP)
    }
    internal fun setStationMode(value: Boolean) {
        if (closed || mutableState.value.busy) return
        platform?.stopDiscovering()
        platform?.clearExpectedCamera(); retryChoice = null
        val saved = platform?.saveConnectionMode(value) == true
        mutableState.value = mutableState.value.copy(stationMode = value, phase = "idle", message = null,
            choices = emptyList(), searching = false, discoveryMessage = null, expectedCamera = null,
            attemptedChoice = null, allowPairing = false, preferencesUnavailable = !saved)
    }
    internal fun setAllowPairing(value: Boolean) {
        if (!closed && !mutableState.value.busy) mutableState.value = mutableState.value.copy(allowPairing = value)
    }
    private fun begin(): Long? {
        if (closed || mutableState.value.busy || mutableState.value.clearingRecovery || nextRequest == Long.MAX_VALUE) return null
        val request = nextRequest++
        mutableState.value = mutableState.value.copy(requestId = request, phase = "connecting", message = null, searching = false, recoveryNotice = null)
        return request
    }
    internal fun connect() {
        val owner = platform ?: return
        val before = mutableState.value
        if (closed || before.busy) return
        retryChoice?.let { previous ->
            if (previous in before.choices) choose(previous)
            else mutableState.value = before.copy(phase = "failed", message = "@ztr|stale_choice")
            return
        }
        val address = NativeCameraEndpointAddress.normalize(before.address)
        if (address == null) {
            mutableState.value = before.copy(phase = "failed", message = "@ztr|invalid_address")
            return
        }
        mutableState.value = before.copy(address = address)
        val request = begin() ?: return
        if (!owner.connectCamera(address, before.stationMode, before.allowPairing, request) && mutableState.value.phase == "connecting")
            publish(request, "failed", null)
    }
    internal fun choose(choice: NativeStationChoice) {
        val owner = platform ?: return
        val before = mutableState.value
        if (!before.stationMode || choice !in before.choices) return
        val request = begin() ?: return
        retryChoice = choice
        mutableState.value = mutableState.value.copy(attemptedChoice = choice.title)
        if (!owner.connectChoice(choice.id, choice.paired, before.allowPairing, request) && mutableState.value.phase == "connecting") publish(request, "failed", null)
    }
    /** Generation and terminal-transition fence: a delayed ready callback cannot undo cancellation. */
    fun publish(requestId: Long, phase: String, message: String?): Boolean {
        val before = mutableState.value
        if (closed || requestId <= 0 || before.requestId != requestId ||
            phase !in setOf("connecting", "ready", "closing", "failed", "idle", "paired")) return false
        if (before.phase == "closing" && phase !in setOf("closing", "failed", "idle")) return false
        if (before.phase == "ready" && phase in setOf("connecting", "paired")) return false
        if (before.phase in setOf("idle", "failed", "paired") && phase in setOf("connecting", "ready", "paired")) return false
        mutableState.value = before.copy(phase = phase, message = message,
            allowPairing = before.allowPairing && phase != "paired")
        return true
    }
    fun publishChoices(values: List<NativeStationChoice>, searching: Boolean, message: String?) {
        if (closed || mutableState.value.busy || !mutableState.value.stationMode) return
        mutableState.value = mutableState.value.copy(choices = values.distinctBy { it.paired to it.id }.take(256),
            searching = searching, discoveryMessage = message)
    }
    fun publishExpectedCamera(description: String?) {
        if (!closed) mutableState.value = mutableState.value.copy(expectedCamera = description)
    }
    internal fun clearExpectedCamera() {
        if (closed || mutableState.value.busy) return
        platform?.clearExpectedCamera(); retryChoice = null
        mutableState.value = mutableState.value.copy(expectedCamera = null, attemptedChoice = null)
    }
    internal fun forgetConfirmed(choice: NativeStationChoice) {
        if (closed || mutableState.value.busy || !choice.paired || choice !in mutableState.value.choices) return
        if (platform?.forgetCameraProfile(choice.id) == true) { retryChoice = null }
    }
    internal fun resetHistoryConfirmed() {
        if (closed || mutableState.value.busy) return
        if (platform?.resetCameraHistory() == true) { retryChoice = null; clearExpectedCamera() }
    }
    internal fun recoverIdentityConfirmed() {
        if (closed || mutableState.value.busy) return
        if (platform?.recoverCameraIdentity() == true) { retryChoice = null; clearExpectedCamera() }
    }
    internal fun discover() {
        if (!closed && !mutableState.value.busy && mutableState.value.stationMode) platform?.discoverCameras()
    }
    internal fun stopSearching() {
        if (closed || mutableState.value.busy) return
        platform?.stopDiscovering()
        mutableState.value = mutableState.value.copy(searching = false)
    }
    internal fun cancel() {
        val value = mutableState.value
        if (closed || value.phase != "connecting") return
        mutableState.value = value.copy(phase = "closing")
        platform?.cancelConnection(value.requestId)
    }
    internal fun disconnect() {
        val value = mutableState.value
        if (closed || !value.ready) return
        mutableState.value = value.copy(phase = "closing")
        platform?.disconnectCamera(value.requestId)
    }
    internal fun openFiles() {
        if (!closed && isReady()) { celebratedRequest = currentRequestId(); platform?.openCameraFiles() }
    }
    internal fun openQueue() {
        if (!closed && isReady()) { celebratedRequest = currentRequestId(); platform?.openTransferQueue() }
    }
    internal fun shouldCelebrate(requestId: Long): Boolean =
        !closed && isReady() && requestId == currentRequestId() && celebratedRequest != requestId
    internal fun celebrationFinished(requestId: Long) {
        if (!shouldCelebrate(requestId)) return
        celebratedRequest = requestId
        platform?.openCameraFiles()
    }
    internal fun settings() { if (!closed) platform?.openNetworkSettings() }
    internal fun diagnosticReport(): String = if (closed) "" else platform?.diagnosticReport()?.take(65536) ?: ""
    internal fun clearDiagnostics() { if (!closed) platform?.clearDiagnostics() }
    internal fun shareDiagnostics(): Boolean = !closed && platform?.shareDiagnostics() == true
    internal fun resetModeConfirmed() {
        if (closed || mutableState.value.busy || platform?.resetConnectionModeAfterConfirmation() != true) return
        mutableState.value = mutableState.value.copy(stationMode = false, preferencesUnavailable = false)
    }
    fun close() {
        if (closed) return
        val owner = platform; val value = mutableState.value
        closed = true; platform = null
        owner?.stopDiscovering()
        if (value.busy) owner?.cancelConnection(value.requestId)
        mutableState.value = value.copy(phase = "idle", choices = emptyList(), searching = false)
    }
}

@Composable
internal fun NativeConnectionHome(model: NativeConnectionHomeModel, language: String, appearance: NativeAppearanceModel? = null) {
    val state by model.state.collectAsState()
    var forgetting by remember(model) { mutableStateOf<NativeStationChoice?>(null) }
    var resettingHistory by remember(model) { mutableStateOf(false) }
    var recoveringIdentity by remember(model) { mutableStateOf(false) }
    var generalSettings by remember(model) { mutableStateOf(false) }
    var diagnostics by remember(model) { mutableStateOf(false) }
    var resettingMode by remember(model) { mutableStateOf(false) }
    fun label(zh: String, en: String) = NativeConnectionHomeText.label(language, zh, en)
    val renderedState = state.copy(message = state.message?.let { NativeTransferMessages.render(it, language) })
    val presentation = renderedState.presentation()
    val selected = homeSelectedConnection(presentation.isConnectedToCamera, presentation.connectionType)
    val clock = remember { kotlin.time.TimeSource.Monotonic.markNow() }
    val totalMs = CONNECT_CELEBRATE_DELAY_MS + CONNECTION_SUCCESS_DURATION_MS
    val elapsed = remember(model, state.requestId, state.ready) {
        mutableLongStateOf(if (!state.ready || model.shouldCelebrate(state.requestId)) 0L else totalMs)
    }
    LaunchedEffect(model, state.requestId, state.ready) {
        val request = state.requestId
        if (!model.shouldCelebrate(request)) return@LaunchedEffect
        val started = kotlin.time.TimeSource.Monotonic.markNow()
        while (model.shouldCelebrate(request)) {
            // One display-synchronised clock drives the original Android timing curves.
            // Scan startup remains owned by the session and never waits for this visual.
            withFrameNanos { elapsed.longValue = started.elapsedNow().inWholeMilliseconds.coerceAtMost(totalMs) }
            if (elapsed.longValue >= totalMs) { model.celebrationFinished(request); break }
        }
    }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val density = androidx.compose.ui.platform.LocalDensity.current
        val widthPx = with(density) { maxWidth.toPx() }
        val heightPx = with(density) { maxHeight.toPx() }
        Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding().verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            ZMark(modifier = Modifier.height(24.dp))
            NativeRecoveryRecordCard(model, language)
            TextButton(onClick = { diagnostics = true }) {
                Text(nativeActionText(language, "传图诊断", "Transfer diagnostics", "傳圖診斷"))
            }
            state.recoveryNotice?.let { code ->
                Text(when (code) {
                    "background" -> nativeActionText(language, "已安全停止后台会话。请确认 Wi-Fi 后重新连接；不会自动继续暂停的任务。",
                        "Background session stopped. Check Wi-Fi and reconnect; paused tasks are not restarted.",
                        "已安全停止背景工作階段。請確認 Wi-Fi 後重新連接；不會自動繼續暫停的工作。")
                    "permissions" -> nativeActionText(language, "请在系统设置确认本地网络权限和 Wi-Fi，再手动重试。",
                        "Check Local Network permission and Wi-Fi in Settings, then retry.",
                        "請在系統設定確認本機網路權限與 Wi-Fi，再手動重試。")
                    else -> nativeActionText(language, "旧连接已关闭。重新连接会再次核对相机身份，旧任务不会直接套用新句柄。",
                        "Old connection closed. Reconnect to verify camera identity; old handles are never reused.",
                        "舊連線已關閉。重新連接會再次核對相機身分，舊工作不會直接套用新控制代碼。")
                }, color = AppTheme.colors.onSurfaceVariant)
            }
            if (appearance != null) TextButton(onClick = { generalSettings = true }) { Text(label("设置", "Settings")) }
            if (model.canOpenPhotoEffects()) {
                TextButton(onClick = model::openPhotoEffects) {
                    Text(label("照片效果", "Photo effects"))
                }
            }
            Text(label("连接相机，浏览与传输原片", "Connect your camera to browse and transfer originals"),
                color = AppTheme.colors.onSurfaceVariant)
            SharedConnectionMethodCard(
                modifier = Modifier.fillMaxWidth().height(380.dp * density.fontScale.coerceAtLeast(1f)),
                failedLabel = label("连接失败", "Connection failed"),
                viewportWidth = widthPx, viewportHeight = heightPx,
                uptimeMillis = { clock.elapsedNow().inWholeMilliseconds },
                modeIcon = { color, modifier -> Icon(Icons.Default.Wifi, contentDescription = null, tint = color, modifier = modifier) },
                title = label("连接相机", "Connect camera"), accent = AppTheme.colors.accentBlue,
                materialSeed = 0x57494649,
                steps = if (state.stationMode) listOf(
                    label("手机与相机加入同一个 Wi-Fi，在相机中启用连接至计算机。", "Join the same Wi-Fi as the camera and enable Connect to computer on the camera."))
                else listOf(label("在相机中启用 Wi-Fi 热点，然后在 iPhone 的系统设置中加入该热点。没有互联网连接是正常现象。", "Enable the camera Wi-Fi hotspot and join it in iPhone Settings. No Internet connection is expected.")),
                modeSelector = { WifiModeTabs(selectedMode = presentation.wirelessMode, enabled = !state.busy,
                    onSelectAp = { model.setStationMode(false) }, onSelectSta = { model.setStationMode(true) }) },
                selected = state.ready, success = state.ready && elapsed.longValue >= CONNECT_CELEBRATE_DELAY_MS,
                attentionActive = !state.busy,
                attentionPhaseOffset = 0f, selectionSceneProgress = { connectionHeroProgress(elapsed.longValue) },
                successEffectProgress = { connectionSuccessProgress(elapsed.longValue) },
                feedbackFollowsModeSelector = true,
                feedback = when (state.phase) {
                    "connecting" -> ConnectionCardFeedback(label("正在连接…", "Connecting…"),
                        renderedState.message, AppTheme.colors.accentBlue, busy = true, multiline = true)
                    "failed" -> ConnectionCardFeedback(label("连接失败", "Connection failed"),
                        renderedState.message, AppTheme.colors.statusError, multiline = true)
                    else -> null
                },
                footer = {
                when (state.phase) {
                    "ready" -> {
                        Text(label("相机会话已连接", "Camera session connected"))
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Button(onClick = model::openFiles, enabled = selected == CameraConnectionType.WIFI) { Text(label("浏览照片", "Browse photos")) }
                            OutlinedButton(onClick = model::openQueue) { Text(label("传输队列", "Transfer queue")) }
                        }
                        TextButton(onClick = model::disconnect) { Text(label("断开连接", "Disconnect")) }
                    }
                    "connecting" -> {
                        LinearProgressIndicator(Modifier.fillMaxWidth())
                        TextButton(onClick = model::cancel) { Text(label("取消连接", "Cancel connection")) }
                    }
                    "closing" -> Text(label("正在关闭连接…", "Closing connection…"))
                    else -> Button(onClick = model::connect) {
                        Text(if (state.phase == "failed") label("重试连接", "Retry connection") else label("连接相机", "Connect camera"))
                    }
                }

                })
            // Platform-specific address/discovery controls do not fork the original card renderer.
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(value = state.address, onValueChange = model::editAddress, enabled = !state.busy,
                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                        autoCorrectEnabled = false, keyboardType = androidx.compose.ui.text.input.KeyboardType.Ascii),
                    singleLine = true, label = { Text(label("相机 IP 地址或主机名", "Camera IP address or hostname")) }, modifier = Modifier.fillMaxWidth())
                if (!state.stationMode) {
                    TextButton(onClick = model::resetApAddress, enabled = !state.busy) { Text(label("恢复相机热点默认地址", "Restore the camera hotspot default address")) }
                    Text(label("热点没有互联网也请保持连接。系统首次询问本地网络权限时请选择允许；超时不代表权限被拒绝。应用设置只管理权限，Wi-Fi 需手动到系统设置切换。", "Stay connected even without Internet. Allow Local Network when prompted; a timeout does not mean permission was denied. App Settings manages permissions; switch Wi-Fi manually in system Settings."))
                }
                if (state.stationMode) {
                    state.expectedCamera?.let {
                        Text(label("将核对所选相机身份：", "Expected camera identity: ") + it)
                        TextButton(onClick = model::clearExpectedCamera, enabled = !state.busy) { Text(label("改选其它相机", "Choose another camera")) }
                    }
                    Row {
                        Checkbox(checked = state.allowPairing, enabled = !state.busy, onCheckedChange = model::setAllowPairing)
                        Text(label("允许首次电脑模式配对（需在相机确认）", "Allow first computer-mode pairing (confirm on the camera)"))
                    }
                    TextButton(onClick = model::discover, enabled = !state.busy && !state.searching) {
                        Text(label("查找相机 / 历史与已配对相机", "Find cameras / history and paired cameras"))
                    }
                    if (state.searching) {
                        LinearProgressIndicator(Modifier.fillMaxWidth())
                        TextButton(onClick = model::stopSearching, enabled = !state.busy) {
                            Text(label("停止查找", "Stop searching"))
                        }
                    }
                    state.discoveryMessage?.let { Text(NativeTransferMessages.render(it, language), color = AppTheme.colors.onSurfaceVariant) }
                    state.choices.forEach { choice ->
                        OutlinedButton(onClick = { model.choose(choice) }, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) {
                            Column { Text(NativeTransferMessages.render(choice.title, language)); Text(NativeTransferMessages.render(choice.detail, language), style = MaterialTheme.typography.bodySmall) }
                        }
                        if (choice.paired) TextButton(onClick = { forgetting = choice }, enabled = !state.busy) {
                            Text(label("忘记此相机记录", "Forget this camera record"))
                        }
                    }
                    TextButton(onClick = { resettingHistory = true }, enabled = !state.busy) {
                        Text(label("备份并重置地址历史", "Back up and reset address history"))
                    }
                    if (state.discoveryMessage != null) TextButton(onClick = { recoveringIdentity = true }, enabled = !state.busy) {
                        Text(label("修复损坏的配对身份文件", "Recover a damaged pairing identity file"))
                    }
                }
                state.attemptedChoice?.let { Text(label("当前连接候选：", "Connection candidate: ") + it) }

            }
            if (state.preferencesUnavailable) Text(label("连接模式无法保存，原偏好文件未被覆盖。", "Connection mode could not be saved; the original preferences were preserved."))
            if (state.preferencesUnavailable) TextButton(enabled = !state.busy, onClick = { resettingMode = true }) {
                Text(nativeActionText(language, "修复连接模式偏好", "Repair connection mode", "修復連接模式偏好"))
            }
            if (state.phase == "paired") Text(label("配对已确认，请完成相机提示后重新连接。", "Pairing confirmed. Finish the camera prompts, then reconnect."))
            else if (state.phase != "connecting" && state.phase != "failed") state.message?.let { Text(NativeTransferMessages.render(it, language)) }
            Text(label("请允许局域网访问。传输期间保持应用在前台；切入后台会关闭当前相机会话。此版本仅提供 AP / 标准 STA，不提供 iOS USB 连接。", "Allow Local Network access. Keep this app in the foreground while transferring; backgrounding closes the camera session. This version supports AP / standard STA, not iOS USB."),
                style = MaterialTheme.typography.bodySmall, color = AppTheme.colors.onSurfaceVariant)
            TextButton(onClick = model::settings) { Text(label("打开应用系统设置", "Open app Settings")) }
        }
    }
    forgetting?.let { choice ->
        AlertDialog(onDismissRequest = { forgetting = null }, title = { Text(label("忘记此相机？", "Forget this camera?")) },
            text = { Text(choice.title + "\n" + label("仅移除此相机的配对标记和地址记录，不删除照片或其它相机。", "Remove only this camera's pairing marker and address. Photos and other cameras are kept.")) },
            confirmButton = { TextButton(onClick = { forgetting = null; model.forgetConfirmed(choice) }) { Text(label("忘记", "Forget")) } },
            dismissButton = { TextButton(onClick = { forgetting = null }) { Text(label("取消", "Cancel")) } })
    }
    if (resettingHistory) AlertDialog(onDismissRequest = { resettingHistory = false }, title = { Text(label("重置地址历史？", "Reset address history?")) },
        text = { Text(label("先备份现有历史文件，再清空地址记录。不会重置安装身份、配对标记或照片。", "Back up the existing history file, then clear addresses. Installation identity, pairing markers and photos are kept.")) },
        confirmButton = { TextButton(onClick = { resettingHistory = false; model.resetHistoryConfirmed() }) { Text(label("备份并重置", "Back up and reset")) } },
        dismissButton = { TextButton(onClick = { resettingHistory = false }) { Text(label("取消", "Cancel")) } })
    if (generalSettings && appearance != null) NativeGeneralSettingsDialog(appearance) { generalSettings = false }
    if (diagnostics) NativeDiagnosticsDialog(model, language) { diagnostics = false }
    if (resettingMode) AlertDialog(onDismissRequest = { resettingMode = false },
        title = { Text(nativeActionText(language, "备份并恢复 AP 模式？", "Back up and restore AP mode?", "備份並恢復 AP 模式？")) },
        text = { Text(nativeActionText(language, "只重置连接模式偏好，不更改配对身份、相机历史或照片。", "Reset only the mode preference; pairing, camera history and photos remain.", "只重置連接模式偏好，不更改配對身分、相機歷史或照片。")) },
        confirmButton = { TextButton(onClick = { resettingMode = false; model.resetModeConfirmed() }) { Text(label("确认恢复", "Confirm recovery")) } },
        dismissButton = { TextButton(onClick = { resettingMode = false }) { Text(label("取消", "Cancel")) } })
    if (recoveringIdentity) AlertDialog(onDismissRequest = { recoveringIdentity = false }, title = { Text(label("恢复损坏的配对身份？", "Recover damaged pairing identity?")) },
        text = { Text(label("仅在身份文件损坏时先备份再重新创建。恢复后所有相机需要重新进行电脑模式配对；照片和地址历史不删除。有效身份不会被重置。", "Only a damaged identity file is backed up and recreated. Afterwards every camera must be paired again. Photos and address history are kept; a valid identity is not reset.")) },
        confirmButton = { TextButton(onClick = { recoveringIdentity = false; model.recoverIdentityConfirmed() }) { Text(label("确认恢复", "Confirm recovery")) } },
        dismissButton = { TextButton(onClick = { recoveringIdentity = false }) { Text(label("取消", "Cancel")) } })
}
