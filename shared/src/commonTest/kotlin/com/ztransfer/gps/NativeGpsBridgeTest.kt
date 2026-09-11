package com.ztransfer.gps

import kotlin.test.*

class NativeGpsBridgeTest {
    @Test fun pairingScalarBridgePreservesEntropyAndSavedIdentity() {
        val entropy = NikonGpsPairingEntropy(-1, Long.MIN_VALUE, Int.MIN_VALUE)
        assertEquals(NikonGpsPairingHandshake.begin(entropy), NativeGpsBridge.beginPairing(
            entropy.device, entropy.timestamp, entropy.nonce, false, 123, 456))
        assertEquals(NikonGpsPairingHandshake.begin(entropy, 0xFFFFFFFFL, 0L), NativeGpsBridge.beginPairing(
            entropy.device, entropy.timestamp, entropy.nonce, true, 0xFFFFFFFFL, 0L))
    }
    @Test fun encodingDelegatesWithoutInventingSatellitesOrAltitude() {
        for (valid in listOf(false, true)) {
            assertContentEquals(GeoPayloadEncoder.encode(39.9042, -116.4074, if (valid) -12.5 else 0.0,
                0, GeoUtcDateTime(2025, 1, 2, 3, 4, 5)),
                NativeGpsBridge.encode(39.9042, -116.4074, -12.5, valid, 2025, 1, 2, 3, 4, 5))
        }
    }
    @Test fun invalidNativeFieldsReturnNullBeforeThrowingConstructor() {
        assertNull(NativeGpsBridge.encode(Double.NaN, 0.0, 0.0, false, 2025, 1, 1, 0, 0, 0))
        assertNull(NativeGpsBridge.encode(0.0, 181.0, 0.0, false, 2025, 1, 1, 0, 0, 0))
        assertNull(NativeGpsBridge.encode(0.0, 0.0, 0.0, false, 2025, 0, 1, 0, 0, 0))
        assertNull(NativeGpsBridge.encode(0.0, 0.0, 0.0, false, 2025, 1, 1, 0, 0, 60))
    }
    @Test fun samplingDefaultsAndCadenceMatchSharedFrequency() {
        for (seconds in listOf(0L, 30L, 60L, 120L, 300L)) {
            val frequency = GpsUpdateFrequency.fromSeconds(seconds)
            assertEquals(frequency.gpsSamplingIntervalMillis, NativeGpsBridge.samplingMillis(seconds))
            assertEquals(frequency.intervalMillis, NativeGpsBridge.writeMillis(seconds))
        }
    }
}
