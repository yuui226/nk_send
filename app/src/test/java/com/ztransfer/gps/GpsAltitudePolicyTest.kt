package com.ztransfer.gps

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GpsAltitudePolicyTest {
    @Test
    fun networkProviderAltitudeIsRejectedEvenWhenMarkedPresent() {
        assertNull(
            trustedGpsAltitude(
                provider = "network",
                hasAltitude = true,
                altitudeMeters = 0.0,
            )
        )
        assertNull(
            trustedGpsAltitude(
                provider = "network",
                hasAltitude = true,
                altitudeMeters = 55.3,
            )
        )
    }

    @Test
    fun genuineGpsZeroRemainsValidAtSeaLevel() {
        assertEquals(
            0.0,
            trustedGpsAltitude(
                provider = GPS_PROVIDER_NAME,
                hasAltitude = true,
                altitudeMeters = 0.0,
            )!!,
            0.0,
        )
    }

    @Test
    fun gpsAltitudeMustBePresentAndFinite() {
        assertNull(trustedGpsAltitude(GPS_PROVIDER_NAME, false, 55.3))
        assertNull(trustedGpsAltitude(GPS_PROVIDER_NAME, true, Double.NaN))
        assertEquals(
            55.3,
            trustedGpsAltitude(GPS_PROVIDER_NAME, true, 55.3)!!,
            0.0,
        )
    }

    @Test
    fun cachedGpsAltitudeIsBoundedByAgeAndDistance() {
        val now = 1_000_000L

        assertTrue(canReuseGpsAltitude(now, now - 30_000L, 120f))
        assertFalse(
            canReuseGpsAltitude(
                now,
                now - GPS_ALTITUDE_MAX_AGE_MS - 1L,
                120f,
            )
        )
        assertFalse(
            canReuseGpsAltitude(
                now,
                now - 30_000L,
                GPS_ALTITUDE_MAX_DISTANCE_METERS + 1f,
            )
        )
    }

    @Test
    fun missingAltitudeWritesZeroInsteadOfBlockingCoordinates() {
        assertEquals(0.0, cameraAltitudeForWrite(null), 0.0)
        assertEquals(55.3, cameraAltitudeForWrite(55.3), 0.0)
    }

    @Test
    fun firstTrustedAltitudeAfterFallbackForcesOneRefresh() {
        assertTrue(shouldForceTrustedAltitudeRefresh(null, 55.3))
        assertTrue(shouldForceTrustedAltitudeRefresh(null, 0.0))
        assertFalse(shouldForceTrustedAltitudeRefresh(null, null))
        assertFalse(shouldForceTrustedAltitudeRefresh(55.3, 56.1))
    }
}
