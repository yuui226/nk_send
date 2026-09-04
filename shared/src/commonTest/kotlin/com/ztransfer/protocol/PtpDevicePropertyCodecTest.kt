package com.ztransfer.protocol

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFails
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PtpDevicePropertyCodecTest {
    @Test
    fun unsignedEnumerationDescriptorMatchesFixedDataset() {
        val descriptor = parsePtpDevicePropDescriptor(
            hex("0F500400016400C8000203006400C800FFFF"),
        )

        assertEquals(0x500F, descriptor.propertyCode)
        assertEquals(0x0004, descriptor.dataType)
        assertTrue(descriptor.writable)
        assertEquals(100L, descriptor.defaultValue)
        assertEquals(200L, descriptor.current)
        assertEquals(2, descriptor.formFlag)
        assertEquals(listOf(100L, 200L, 65535L), descriptor.enumValues)
        assertNull(descriptor.rangeMin)
    }

    @Test
    fun signedRangeAndBooleanRangeMatchFixedDatasets() {
        val signed = parsePtpDevicePropDescriptor(
            hex("1050030001000018FC0178EC88134D01"),
        )
        assertEquals(0L, signed.defaultValue)
        assertEquals(-1000L, signed.current)
        assertEquals(-5000L, signed.rangeMin)
        assertEquals(5000L, signed.rangeMax)
        assertEquals(333L, signed.rangeStep)

        val boolean = parsePtpDevicePropDescriptor(hex("54D0020001000101000101"))
        assertEquals(1L, boolean.current)
        assertEquals(0L, boolean.rangeMin)
        assertEquals(1L, boolean.rangeMax)
        assertEquals(1L, boolean.rangeStep)
    }

    @Test
    fun writableAndUnknownFormRulesIgnoreTrailingBytes() {
        val base = hex("01500200020506037F")
        val descriptor = parsePtpDevicePropDescriptor(base + byteArrayOf(0x55))

        assertFalse(descriptor.writable)
        assertEquals(5L, descriptor.defaultValue)
        assertEquals(6L, descriptor.current)
        assertEquals(3, descriptor.formFlag)
        assertEquals(emptyList(), descriptor.enumValues)
        assertNull(descriptor.rangeMin)

        val echoFailure = runCatching {
            parsePtpDevicePropDescriptor(0x5002, hex("0150"))
        }.exceptionOrNull()
        requireNotNull(echoFailure)
        assertTrue(echoFailure.message.orEmpty().contains("descriptor echoed 0x5001"))
    }

    @Test
    fun scalarSignednessAndWireEncodingStayCompatible() {
        assertValue(0x0001, "FF", -1L)
        assertValue(0x0002, "FF", 255L)
        assertValue(0x0003, "0080", -32768L)
        assertValue(0x0004, "FFFF", 65535L)
        assertValue(0x0005, "00000080", Int.MIN_VALUE.toLong())
        assertValue(0x0006, "FFFFFFFF", 0xFFFFFFFFL)
        assertValue(0x0007, "FFFFFFFFFFFFFFFF", -1L)
        assertValue(0x0008, "FFFFFFFFFFFFFFFF", -1L)

        assertEquals(1, ptpScalarSize(0x0002))
        assertEquals(2, ptpScalarSize(0x0003))
        assertEquals(4, ptpScalarSize(0x0006))
        assertEquals(8, ptpScalarSize(0x0008))
        assertNull(ptpScalarSize(0xFFFF))
        assertContentEquals(hex("EFCDAB89"), encodePtpScalar(0x0006, 0x89ABCDEFL))
    }

    @Test
    fun nonScalarAndMalformedArrayValuesAreBounded() {
        val stringValue = decodePtpTypedValue(0xFFFF, hex("0241000000"))
        assertFalse(stringValue.isScalar)
        assertEquals(0L, stringValue.value)

        val arrayValue = decodePtpTypedValue(0x4004, hex("020000000100FFFF"))
        assertFalse(arrayValue.isScalar)
        assertFails { decodePtpTypedValue(0x4004, hex("FFFFFFFF")) }
        assertFails { decodePtpTypedValue(0x0009, ByteArray(15)) }
    }

    @Test
    fun vendorUInt16CodesDeduplicateAndFalseCountsFail() {
        assertEquals(
            listOf(0x5001, 0xD067),
            parseVendorCodes16(hex("030000000150015067D0")).toList(),
        )
        assertFails { parseVendorCodes16(hex("FFFFFFFF")) }
    }

    private fun assertValue(dataType: Int, encoded: String, expected: Long) {
        val decoded = decodePtpTypedValue(dataType, hex(encoded))
        assertTrue(decoded.isScalar)
        assertEquals(expected, decoded.value)
    }

    private fun hex(value: String): ByteArray {
        require(value.length % 2 == 0)
        return ByteArray(value.length / 2) { index ->
            value.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }
}
