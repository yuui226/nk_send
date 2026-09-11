package com.ztransfer.gps

/** Non-throwing scalar entry points for Apple location services; protocol bytes remain shared. */
object NativeGpsBridge {
    /** Avoid boxed nullable Long construction at the Swift boundary. Entropy mapping is unchanged. */
    fun beginPairing(deviceEntropy: Int, timestampEntropy: Long, nonceEntropy: Int,
                     hasSavedIdentity: Boolean, savedDevice: Long, savedNonce: Long): NikonGpsPairingDecision =
        NikonGpsPairingHandshake.begin(NikonGpsPairingEntropy(deviceEntropy, timestampEntropy, nonceEntropy),
            deviceOverride = savedDevice.takeIf { hasSavedIdentity }, nonceOverride = savedNonce.takeIf { hasSavedIdentity })

    fun samplingMillis(frequencySeconds: Long): Long = GpsUpdateFrequency.fromSeconds(frequencySeconds).gpsSamplingIntervalMillis
    fun writeMillis(frequencySeconds: Long): Long = GpsUpdateFrequency.fromSeconds(frequencySeconds).intervalMillis
    fun encode(latitude: Double, longitude: Double, altitude: Double, validAltitude: Boolean,
               year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int): ByteArray? {
        if (latitude !in -90.0..90.0 || longitude !in -180.0..180.0 || year !in 0..65535 ||
            month !in 1..12 || day !in 1..31 || hour !in 0..23 || minute !in 0..59 || second !in 0..59) return null
        return GeoPayloadEncoder.encode(latitude, longitude,
            cameraAltitudeForWrite(altitude.takeIf { validAltitude && it.isFinite() }),
            satellites = 0, // CoreLocation does not expose a satellite count. Never fabricate one.
            timestamp = GeoUtcDateTime(year, month, day, hour, minute, second))
    }
}
