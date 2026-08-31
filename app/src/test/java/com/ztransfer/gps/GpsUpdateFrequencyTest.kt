package com.ztransfer.gps

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class GpsUpdateFrequencyTest {
    @Test
    fun writeCadencesMapToConservativeLocationSampling() {
        val expected = listOf(
            Triple(GpsUpdateFrequency.THIRTY_SECONDS, 5_000L, 15_000L),
            Triple(GpsUpdateFrequency.ONE_MINUTE, 10_000L, 15_000L),
            Triple(GpsUpdateFrequency.TWO_MINUTES, 20_000L, 20_000L),
            Triple(GpsUpdateFrequency.FIVE_MINUTES, 30_000L, 30_000L),
        )

        expected.forEach { (frequency, gpsInterval, networkInterval) ->
            assertEquals(gpsInterval, frequency.gpsSamplingIntervalMillis)
            assertEquals(networkInterval, frequency.networkSamplingIntervalMillis)
        }
    }

    @Test
    fun samplingIsBoundedAndNeverSlowerThanTheWriteCadence() {
        GpsUpdateFrequency.entries.forEach { frequency ->
            assertTrue(frequency.gpsSamplingIntervalMillis <= 30_000L)
            assertTrue(frequency.networkSamplingIntervalMillis <= 30_000L)
            assertTrue(frequency.gpsSamplingIntervalMillis <= frequency.intervalMillis)
            assertTrue(frequency.networkSamplingIntervalMillis <= frequency.intervalMillis)
            assertTrue(
                frequency.networkSamplingIntervalMillis >=
                    frequency.gpsSamplingIntervalMillis,
            )
        }
    }
}
