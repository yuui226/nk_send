package com.ztransfer.test

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertFailsWith

class FixedSamplesTest {
    @Test
    fun hexadecimalSamplesAcceptBothCasesAndPreserveHighBits() {
        assertContentEquals(byteArrayOf(), hexBytes(""))
        assertContentEquals(
            byteArrayOf(0x00, 0x7F, 0x80.toByte(), 0xFF.toByte()),
            hexBytes("007f80FF"),
        )
    }

    @Test
    fun malformedHexSamplesFailAtTheFixtureBoundary() {
        assertFailsWith<IllegalArgumentException> { hexBytes("ABC") }
        assertFailsWith<IllegalArgumentException> { hexBytes("GG") }
    }

    @Test
    fun integerByteSamplesKeepTheExistingLowEightBitConversion() {
        assertContentEquals(
            byteArrayOf(0x00, 0x7F, 0x80.toByte(), 0xFF.toByte()),
            byteValues(0, 127, 128, 255),
        )
    }
}
