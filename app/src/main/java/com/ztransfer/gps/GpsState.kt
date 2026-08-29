package com.ztransfer.gps

/** Minimal user-facing GPS state. Protocol and Bluetooth details stay in the service. */
enum class GpsStatus {
    OFF,
    STARTING,
    NEEDS_CAMERA,
    CONNECTING,
    PAIRING,
    WAITING_FIX,
    READY,
    ERROR,
}

data class GpsState(
    val enabled: Boolean = false,
    val status: GpsStatus = GpsStatus.OFF,
    val cameraName: String? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val accuracyMeters: Float? = null,
    val lastSentAtMs: Long? = null,
    val message: String? = null,
)
