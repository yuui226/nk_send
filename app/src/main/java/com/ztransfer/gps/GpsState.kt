package com.ztransfer.gps

/** Minimal user-facing GPS state. Protocol and Bluetooth details stay in the service. */
enum class GpsStatus {
    OFF,
    STARTING,
    SEARCHING,
    NEEDS_CAMERA,
    CONNECTING,
    PAIRING,
    CAMERA_CONFIRM,
    PAIRING_SUCCESS,
    CONNECTED,
    WRITING,
    WAITING_FIX,
    READY,
    AP_UNAVAILABLE,
    ERROR,
}

data class GpsState(
    val enabled: Boolean = false,
    val status: GpsStatus = GpsStatus.OFF,
    val cameraName: String? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val altitudeMeters: Double? = null,
    val accuracyMeters: Float? = null,
    val lastSentAtMs: Long? = null,
    val message: String? = null,
)

internal enum class GpsRecoveryTarget {
    LOCATION_ONLY,
    FULL_CONNECTION,
}

/** Keep an established camera session when only the phone location setup needs another attempt. */
internal fun gpsRecoveryTarget(
    cameraReady: Boolean,
    bleClientRunning: Boolean,
): GpsRecoveryTarget = if (cameraReady && bleClientRunning) {
    GpsRecoveryTarget.LOCATION_ONLY
} else {
    GpsRecoveryTarget.FULL_CONNECTION
}
