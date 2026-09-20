package com.ztransfer.util

import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class CoordinateFormatTest {
    @Test
    fun matchesCameraDegreesAndDecimalMinutes() {
        assertEquals("N 24°29.369'", formatDegreesMinutesLatitude(24.0 + 29.369 / 60))
        assertEquals("N 31°13.824', E 121°28.422'", formatDegreesMinutesCoordinates(31.2304, 121.4737))
        assertEquals("S 33°52.128', E 151°12.558'", formatDegreesMinutesCoordinates(-33.8688, 151.2093))
        assertEquals("N 40°42.768', W 74°00.360'", formatDegreesMinutesCoordinates(40.7128, -74.006))
    }

    @Test
    fun roundsMinutesAndCarriesIntoDegrees() {
        assertEquals("N 25°00.000'", formatDegreesMinutesLatitude(24.0 + 59.9996 / 60))
        assertEquals("S 25°00.000'", formatDegreesMinutesLatitude(-(24.0 + 59.9996 / 60)))
        assertEquals("E 180°00.000'", formatDegreesMinutesLongitude(179.99999999))
        assertEquals("N 90°00.000'", formatDegreesMinutesLatitude(90.0))
        assertEquals("S 90°00.000', W 180°00.000'", formatDegreesMinutesCoordinates(-90.0, -180.0))
        assertEquals("N 0°00.000', E 0°00.000'", formatDegreesMinutesCoordinates(0.0, 0.0))
    }

    @Test
    fun usesCameraDecimalPointRegardlessOfPhoneLocale() {
        val previous = Locale.getDefault()
        try {
            Locale.setDefault(Locale.GERMANY)
            assertEquals("N 24°29.369'", formatDegreesMinutesLatitude(24.0 + 29.369 / 60))
        } finally { Locale.setDefault(previous) }
    }

    @Test
    fun invalidCoordinatesAreRejectedBeforeFormatting() {
        for (latitude in listOf(91.0, -91.0, Double.NaN, Double.POSITIVE_INFINITY)) {
            assertThrows(IllegalArgumentException::class.java) { formatDegreesMinutesLatitude(latitude) }
        }
        for (longitude in listOf(181.0, -181.0, Double.NaN, Double.NEGATIVE_INFINITY)) {
            assertThrows(IllegalArgumentException::class.java) { formatDegreesMinutesLongitude(longitude) }
        }
    }
}
