package com.ztransfer.util

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class CoordinateFormatTest {
    @Test
    fun decimalDegreesUseHemisphereDirectionsInsteadOfSignedValues() {
        assertEquals(
            "31.23040°N, 121.47370°E",
            formatDecimalDegreeCoordinates(31.2304, 121.4737, fractionDigits = 5),
        )
        assertEquals(
            "33.86880°S, 151.20930°E",
            formatDecimalDegreeCoordinates(-33.8688, 151.2093, fractionDigits = 5),
        )
        assertEquals(
            "40.7128°N, 74.0060°W",
            formatDecimalDegreeCoordinates(40.7128, -74.006, fractionDigits = 4),
        )
        assertEquals("31.23040°N", formatDecimalDegreeLatitude(31.2304, fractionDigits = 5))
        assertEquals("121.47370°E", formatDecimalDegreeLongitude(121.4737, fractionDigits = 5))
    }

    @Test
    fun invalidCoordinatesAreRejectedBeforeFormatting() {
        assertThrows(IllegalArgumentException::class.java) {
            formatDecimalDegreeCoordinates(91.0, 0.0, fractionDigits = 5)
        }
        assertThrows(IllegalArgumentException::class.java) {
            formatDecimalDegreeCoordinates(0.0, 181.0, fractionDigits = 5)
        }
        assertThrows(IllegalArgumentException::class.java) {
            formatDecimalDegreeLatitude(Double.NaN, fractionDigits = 5)
        }
        assertThrows(IllegalArgumentException::class.java) {
            formatDecimalDegreeLongitude(Double.POSITIVE_INFINITY, fractionDigits = 5)
        }
        assertThrows(IllegalArgumentException::class.java) {
            formatDecimalDegreeLatitude(0.0, fractionDigits = -1)
        }
        assertThrows(IllegalArgumentException::class.java) {
            formatDecimalDegreeLatitude(0.0, fractionDigits = 9)
        }
    }

    @Test
    fun roundingSignedZeroAndLegalLimitsStayStable() {
        assertEquals("1.01°N", formatDecimalDegreeLatitude(1.005, fractionDigits = 2))
        assertEquals("0.00001°S", formatDecimalDegreeLatitude(-0.000005, fractionDigits = 5))
        assertEquals("0.00000°N", formatDecimalDegreeLatitude(-0.0, fractionDigits = 5))
        assertEquals("90°S", formatDecimalDegreeLatitude(-90.0, fractionDigits = 0))
        assertEquals("180.00000000°E", formatDecimalDegreeLongitude(180.0, fractionDigits = 8))
    }
}
