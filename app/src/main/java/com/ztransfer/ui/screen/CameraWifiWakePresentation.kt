package com.ztransfer.ui.screen

import androidx.annotation.StringRes
import com.ztransfer.R
import com.ztransfer.gps.CameraWifiWakeError

/** Keep protocol failures out of connection-card copy. */
@get:StringRes
internal val CameraWifiWakeError.messageRes: Int
    get() = when (this) {
        CameraWifiWakeError.NOT_PAIRED -> R.string.wifi_wake_not_paired
        CameraWifiWakeError.GPS_ACTIVE -> R.string.wifi_wake_gps_active
        CameraWifiWakeError.BLUETOOTH_OFF -> R.string.wifi_wake_bluetooth_off
        CameraWifiWakeError.PERMISSION_REQUIRED -> R.string.wifi_wake_permission_required
        CameraWifiWakeError.UNSUPPORTED -> R.string.wifi_wake_unsupported
        CameraWifiWakeError.CONNECTION_FAILED -> R.string.wifi_wake_connection_failed
        CameraWifiWakeError.WRITE_FAILED -> R.string.wifi_wake_write_failed
        CameraWifiWakeError.TIMEOUT -> R.string.wifi_wake_timeout
    }
