package com.ztransfer.gps

enum class GpsRecoveryTarget {
    LOCATION_ONLY,
    FULL_CONNECTION,
}

/** LE identity completion means the camera is connected; GEO delivery is a later work state. */
fun gpsStatusAfterCameraReady(preserveReadyDuringReconnect: Boolean): GpsStatus =
    if (preserveReadyDuringReconnect) GpsStatus.READY else GpsStatus.CONNECTED

/** Keep an established camera session when only the phone location setup needs another attempt. */
fun gpsRecoveryTarget(
    cameraReady: Boolean,
    bleClientRunning: Boolean,
): GpsRecoveryTarget = if (cameraReady && bleClientRunning) {
    GpsRecoveryTarget.LOCATION_ONLY
} else {
    GpsRecoveryTarget.FULL_CONNECTION
}
