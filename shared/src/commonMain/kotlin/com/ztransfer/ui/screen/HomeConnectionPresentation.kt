package com.ztransfer.ui.screen

import com.ztransfer.connection.StaConnectionStatus
import com.ztransfer.connection.WifiConnectionStatus
import com.ztransfer.connection.WirelessMode
import com.ztransfer.protocol.CameraConnectionType

/** Platform-neutral connection fields rendered by the home screen. */
data class HomeConnectionUiState(
    val isConnectedToCamera: Boolean,
    val connectionType: CameraConnectionType?,
    val wirelessMode: WirelessMode,
    val isStaConnection: Boolean,
    val staConnectionStatus: StaConnectionStatus,
    val staConnectionError: String?,
    val usbConnectionError: String?,
    val wifiConnectionStatus: WifiConnectionStatus,
)

enum class ConnectionHapticOutcome {
    NONE,
    USB_SUCCESS,
    AP_SUCCESS,
    STA_SUCCESS,
    USB_FAILURE,
    AP_FAILURE,
    STA_FAILURE;

    val isFailure: Boolean
        get() = this == USB_FAILURE || this == AP_FAILURE || this == STA_FAILURE
}

private val AP_FAILURE_STATUSES = setOf(
    WifiConnectionStatus.NOT_FOUND,
    WifiConnectionStatus.REFUSED,
    WifiConnectionStatus.FAILED,
)

/** Collapses detailed connection transitions into one user-visible haptic outcome. */
fun HomeConnectionUiState.connectionHapticOutcome(): ConnectionHapticOutcome = when {
    isConnectedToCamera && connectionType == CameraConnectionType.USB ->
        ConnectionHapticOutcome.USB_SUCCESS
    isConnectedToCamera && connectionType == CameraConnectionType.WIFI && isStaConnection ->
        ConnectionHapticOutcome.STA_SUCCESS
    isConnectedToCamera && connectionType == CameraConnectionType.WIFI ->
        ConnectionHapticOutcome.AP_SUCCESS
    connectionType == CameraConnectionType.USB && usbConnectionError != null ->
        ConnectionHapticOutcome.USB_FAILURE
    wirelessMode == WirelessMode.STA && staConnectionStatus == StaConnectionStatus.FAILED ->
        ConnectionHapticOutcome.STA_FAILURE
    wirelessMode == WirelessMode.AP && connectionType != CameraConnectionType.USB &&
        wifiConnectionStatus in AP_FAILURE_STATUSES -> ConnectionHapticOutcome.AP_FAILURE
    else -> ConnectionHapticOutcome.NONE
}

/** USB remains selected on physical detection; Wi-Fi requires an established camera session. */
fun homeSelectedConnection(
    connected: Boolean,
    connectionType: CameraConnectionType?,
): CameraConnectionType? = when {
    connectionType == CameraConnectionType.USB -> CameraConnectionType.USB
    connected && connectionType == CameraConnectionType.WIFI -> CameraConnectionType.WIFI
    else -> null
}

fun shouldShowWifiConnectionFeedback(connectionType: CameraConnectionType?): Boolean =
    connectionType != CameraConnectionType.USB

fun shouldShowCameraHotspotFeedback(
    connectionType: CameraConnectionType?,
    isStaConnection: Boolean = false,
    staStatus: StaConnectionStatus = StaConnectionStatus.IDLE,
    wirelessMode: WirelessMode = WirelessMode.AP,
): Boolean = shouldShowWifiConnectionFeedback(connectionType) &&
    wirelessMode == WirelessMode.AP && !isStaConnection &&
    staStatus == StaConnectionStatus.IDLE
