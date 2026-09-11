package com.ztransfer.ui.util

import org.junit.Assert.assertEquals
import org.junit.Test

class FormatTest {
    @Test
    fun fileSizeKeepsThresholdsIntegerKilobytesAndUsRounding() {
        val cases = listOf(
            -1L to "-1 B",
            1_023L to "1023 B",
            1_024L to "1 KB",
            1_048_575L to "1023 KB",
            1_048_576L to "1.0 MB",
            1_310_720L to "1.3 MB",
            1_073_741_823L to "1024.0 MB",
            1_073_741_824L to "1.00 GB",
            1_207_959_552L to "1.13 GB",
            Long.MAX_VALUE to "8589934592.00 GB",
        )
        cases.forEach { (input, expected) -> assertEquals(expected, formatFileSize(input)) }
    }

    @Test
    fun speedKeepsThresholdsAndUsRounding() {
        val cases = listOf(
            -1L to "-1 B/s",
            1_023L to "1023 B/s",
            1_024L to "1.0 KB/s",
            1_280L to "1.3 KB/s",
            1_048_575L to "1024.0 KB/s",
            1_048_576L to "1.0 MB/s",
            Long.MAX_VALUE to "8796093022208.0 MB/s",
        )
        cases.forEach { (input, expected) -> assertEquals(expected, formatSpeed(input)) }
    }

    @Test
    fun durationKeepsSubMinuteRoundingAndWholeSecondMinuteDisplay() {
        val cases = listOf(
            -1L to "0.0s",
            50L to "0.1s",
            59_949L to "59.9s",
            59_950L to "60.0s",
            59_999L to "60.0s",
            60_000L to "1m00s",
            60_999L to "1m00s",
            61_000L to "1m01s",
            125_999L to "2m05s",
            Long.MAX_VALUE to "153722867280912m55s",
        )
        cases.forEach { (input, expected) -> assertEquals(expected, formatDuration(input)) }
    }
}
