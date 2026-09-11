package com.ztransfer.protocol

import com.ztransfer.test.hexBytes
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull

class PtpArrayDatasetParserTest {
    @Test
    fun validEmptyArrayIsDistinctFromMalformedPayload() {
        assertEquals(emptyList(), parsePtpUInt32Array(hexBytes("00000000")))

        assertNull(parsePtpUInt32Array(null))
        assertNull(parsePtpUInt32Array(byteArrayOf()))
        assertNull(parsePtpUInt32Array(hexBytes("000000")))
        assertNull(parsePtpUInt32Array(hexBytes("FFFFFFFF")))
        assertNull(parsePtpUInt32Array(hexBytes("0200000001000000")))
    }

    @Test
    fun orderDuplicatesAndUnsignedBitPatternsArePreserved() {
        val parsed = parsePtpUInt32Array(
            hexBytes("04000000020000000100000002000000FFFFFFFF"),
        )

        assertContentEquals(listOf(2, 1, 2, -1), parsed)
    }

    @Test
    fun trailingBytesAfterDeclaredValuesRemainAccepted() {
        assertContentEquals(
            listOf(0x291961F5, 0x091961E7),
            parsePtpUInt32Array(hexBytes("02000000F5611929E7611909AABBCC")),
        )
    }

}
