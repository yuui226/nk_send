package com.ztransfer.format

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class TextFormatPolicyTest {
    @Test
    fun fileSizeSelectsTheOriginalBinaryThresholdsAndPrecision() {
        val calls = mutableListOf<Pair<Double, Int>>()
        val renderer = recordingRenderer(calls)
        assertEquals("-1 B", formatFileSizeText(-1L, renderer))
        assertEquals("1023 B", formatFileSizeText(1_023L, renderer))
        assertEquals("1 KB", formatFileSizeText(1_024L, renderer))
        assertEquals("1023 KB", formatFileSizeText(1_048_575L, renderer))
        assertEquals("# MB", formatFileSizeText(1_048_576L, renderer))
        assertEquals("# MB", formatFileSizeText(1_310_720L, renderer))
        assertEquals("# GB", formatFileSizeText(1_073_741_824L, renderer))
        assertEquals(listOf(1.0 to 1, 1.25 to 1, 1.0 to 2), calls)
    }

    @Test
    fun speedAndDurationKeepThresholdAndMinuteSplitRules() {
        val speedCalls = mutableListOf<Pair<Double, Int>>()
        val speedRenderer = recordingRenderer(speedCalls)
        assertEquals("# KB/s", formatTransferSpeedText(1_280L, speedRenderer))
        assertEquals("# KB/s", formatTransferSpeedText(1_048_575L, speedRenderer))
        assertEquals("# MB/s", formatTransferSpeedText(1_048_576L, speedRenderer))
        assertEquals(
            listOf(1.25 to 1, 1023.9990234375 to 1, 1.0 to 1),
            speedCalls,
        )

        val durationCalls = mutableListOf<Pair<Double, Int>>()
        val durationRenderer = recordingRenderer(durationCalls)
        assertEquals("0.0s", formatDurationText(-1L, durationRenderer))
        assertEquals("#s", formatDurationText(59_999L, durationRenderer))
        assertEquals("1m00s", formatDurationText(60_000L, durationRenderer))
        assertEquals("2m05s", formatDurationText(125_999L, durationRenderer))
        assertEquals(listOf(59.999 to 1), durationCalls)
    }

    @Test
    fun coordinatesKeepValidationHemisphereAndPunctuationInCommonCode() {
        val calls = mutableListOf<Pair<Double, Int>>()
        val renderer = recordingRenderer(calls)
        assertEquals(
            "#°N, #°E",
            formatDecimalDegreeCoordinatesText(31.2304, 121.4737, 5, renderer),
        )
        assertEquals("#°S", formatDecimalDegreeLatitudeText(-0.000005, 5, renderer))
        assertEquals("#°N", formatDecimalDegreeLatitudeText(-0.0, 5, renderer))
        assertEquals("#°W", formatDecimalDegreeLongitudeText(-180.0, 8, renderer))
        assertEquals(
            listOf(31.2304 to 5, 121.4737 to 5, 0.000005 to 5, 0.0 to 5, 180.0 to 8),
            calls,
        )

        assertEquals(
            "latitude out of range",
            assertFailsWith<IllegalArgumentException> {
                formatDecimalDegreeLatitudeText(Double.NaN, 5, renderer)
            }.message,
        )
        assertEquals(
            "fractionDigits out of range",
            assertFailsWith<IllegalArgumentException> {
                formatDecimalDegreeLongitudeText(0.0, 9, renderer)
            }.message,
        )
    }

    private fun recordingRenderer(calls: MutableList<Pair<Double, Int>>): (Double, Int) -> String =
        { value, digits ->
            calls += value to digits
            "#"
        }
}
