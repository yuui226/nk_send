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
    val placeName: String? = null,
    val accuracyMeters: Float? = null,
    val lastSentAtMs: Long? = null,
    val message: String? = null,
)
