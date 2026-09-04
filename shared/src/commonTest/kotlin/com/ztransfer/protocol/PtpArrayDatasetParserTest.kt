package com.ztransfer.protocol

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull

class PtpArrayDatasetParserTest {
    @Test
    fun validEmptyArrayIsDistinctFromMalformedPayload() {
        assertEquals(emptyList(), parsePtpUInt32Array(hex("00000000")))

        assertNull(parsePtpUInt32Array(null))
        assertNull(parsePtpUInt32Array(byteArrayOf()))
        assertNull(parsePtpUInt32Array(hex("000000")))
        assertNull(parsePtpUInt32Array(hex("FFFFFFFF")))
        assertNull(parsePtpUInt32Array(hex("0200000001000000")))
    }

    @Test
    fun orderDuplicatesAndUnsignedBitPatternsArePreserved() {
        val parsed = parsePtpUInt32Array(
            hex("04000000020000000100000002000000FFFFFFFF"),
        )

        assertContentEquals(listOf(2, 1, 2, -1), parsed)
    }

    @Test
    fun trailingBytesAfterDeclaredValuesRemainAccepted() {
        assertContentEquals(
            listOf(0x291961F5, 0x091961E7),
            parsePtpUInt32Array(hex("02000000F5611929E7611909AABBCC")),
        )
    }

    private fun hex(value: String): ByteArray = value.chunked(2)
        .map { it.toInt(16).toByte() }
        .toByteArray()
}
