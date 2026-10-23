package com.ztransfer.gps

enum class CameraWifiWakeStatus { IDLE, CONNECTING, SENDING, REQUEST_SENT, ERROR }

enum class CameraWifiWakeError {
    NOT_PAIRED,
    GPS_ACTIVE,
    BLUETOOTH_OFF,
    PERMISSION_REQUIRED,
    UNSUPPORTED,
    CONNECTION_FAILED,
    WRITE_FAILED,
    TIMEOUT,
}

data class CameraWifiWakeState(
    val status: CameraWifiWakeStatus = CameraWifiWakeStatus.IDLE,
    val error: CameraWifiWakeError? = null,
) {
    val isBusy: Boolean
        get() = status == CameraWifiWakeStatus.CONNECTING || status == CameraWifiWakeStatus.SENDING
}

/** A one-shot request: terminal/late BLE callbacks cannot restart it or turn a failure into success. */
internal class CameraWifiWakeAttempt {
    var state = CameraWifiWakeState(CameraWifiWakeStatus.CONNECTING)
        private set

    fun ready(): Boolean {
        if (state.status != CameraWifiWakeStatus.CONNECTING) return false
        state = CameraWifiWakeState(CameraWifiWakeStatus.SENDING)
        return true
    }

    fun written(success: Boolean): Boolean {
        if (state.status != CameraWifiWakeStatus.SENDING) return false
        state = if (success) CameraWifiWakeState(CameraWifiWakeStatus.REQUEST_SENT)
        else CameraWifiWakeState(CameraWifiWakeStatus.ERROR, CameraWifiWakeError.WRITE_FAILED)
        return true
    }

    fun fail(error: CameraWifiWakeError): Boolean {
        if (!state.isBusy) return false
        state = CameraWifiWakeState(CameraWifiWakeStatus.ERROR, error)
        return true
    }

    fun cancel() {
        if (state.isBusy) state = CameraWifiWakeState()
    }
}

internal fun cameraWifiWakePreflight(
    gpsEnabled: Boolean,
    hasSavedIdentity: Boolean,
    hasSavedAddress: Boolean,
    bluetoothEnabled: Boolean,
    hasConnectPermission: Boolean,
): CameraWifiWakeError? = when {
    gpsEnabled -> CameraWifiWakeError.GPS_ACTIVE
    !hasSavedIdentity || !hasSavedAddress -> CameraWifiWakeError.NOT_PAIRED
    !hasConnectPermission -> CameraWifiWakeError.PERMISSION_REQUIRED
    !bluetoothEnabled -> CameraWifiWakeError.BLUETOOTH_OFF
    else -> null
}

/** A failed discovery/timeout is not evidence that the model lacks the Wi-Fi command. */
internal fun cameraWifiWakeError(message: String): CameraWifiWakeError = when {
    message.contains("permission", ignoreCase = true) -> CameraWifiWakeError.PERMISSION_REQUIRED
    message.contains("Bluetooth unavailable", ignoreCase = true) -> CameraWifiWakeError.BLUETOOTH_OFF
    message == "Camera Wi-Fi service unavailable" ||
        message == "Camera GPS service unavailable" ||
        message == "Camera GPS notification unavailable" -> CameraWifiWakeError.UNSUPPORTED
    message.contains("timeout", ignoreCase = true) -> CameraWifiWakeError.TIMEOUT
    message.contains("pairing", ignoreCase = true) ||
        message.contains("identity expired", ignoreCase = true) ||
        message.contains("配对") -> CameraWifiWakeError.NOT_PAIRED
    else -> CameraWifiWakeError.CONNECTION_FAILED
}
