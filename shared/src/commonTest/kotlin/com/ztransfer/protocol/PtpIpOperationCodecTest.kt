package com.ztransfer.protocol

import com.ztransfer.test.hexBytes
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertContentEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PtpIpOperationCodecTest {
    @Test
    fun nativeIdentifiersPreserveEmptyMalformedOrderAndUnsignedBits() {
        val bytes = hexBytes("0400000001000100FFFFFFFF00000080FFFFFFFFAB")
        assertContentEquals(intArrayOf(0x10001, -1, Int.MIN_VALUE, -1), PtpIpOperationCodec.decodeIdentifiers(bytes))
        assertContentEquals(parsePtpUInt32Array(bytes)?.toIntArray(), PtpIpOperationCodec.decodeIdentifiers(bytes))
        assertContentEquals(intArrayOf(), PtpIpOperationCodec.decodeIdentifiers(hexBytes("00000000")))
        for (length in 0 until bytes.size - 1) {
            assertNull(PtpIpOperationCodec.decodeIdentifiers(bytes.copyOf(length)))
        }
        assertNull(PtpIpOperationCodec.decodeIdentifiers(hexBytes("FFFFFFFF")))
    }

    @Test
    fun nativeObjectInfoKeepsSharedFolderAndIncompleteIdentityFlags() {
        for (length in 0 until 53) {
            assertNull(PtpIpOperationCodec.decodeObjectInfo(7, ByteArray(length)))
        }
        val folder = ByteArray(53).also { it[4] = 1; it[5] = 0x30 }
        val association = requireNotNull(PtpIpOperationCodec.decodeObjectInfo(7, folder))
        assertTrue(association.isAssociation)
        assertTrue(association.identityComplete)
        assertNull(association.fileName)
        val partial = ByteArray(53).also { it[4] = 1; it[5] = 0x38; it[52] = 20 }
        val info = requireNotNull(PtpIpOperationCodec.decodeObjectInfo(7, partial))
        assertFalse(info.isAssociation)
        assertFalse(info.identityComplete)
        assertEquals(parsePtpObjectInfo(7, partial)?.fileName, info.fileName)
    }

    @Test
    fun nativeObjectInfoPreservesUnicodeAndUnknownSize() {
        val payload = hexBytes(
            "0100010001B10080FFFFFFFF01380403020140010000F00000004020000080150000" +
                "0E000000000000000000000000007856341209677147723DD800DE2E004E00450046000000" +
                "1032003000320036003000390030003400540031003500300036003000370000000000",
        )
        val info = requireNotNull(PtpIpOperationCodec.decodeObjectInfo(-1, payload))
        assertEquals(-1, info.handle)
        assertEquals(0x10001, info.storageId)
        assertEquals("照片😀.NEF", info.fileName)
        assertEquals("20260904T150607", info.captureDate)
        assertEquals(PtpConstants.SIZE_UNKNOWN, info.size)
        assertTrue(info.isProtected)
        assertTrue(info.identityComplete)
    }

    @Test
    fun responsePreservesUnsignedCodeAndTransactionBits() {
        val response = requireNotNull(PtpIpOperationCodec.decodeResponse(hexBytes("05A0EFCDAB89")))
        assertEquals(0xA005, response.code)
        assertEquals(0x89ABCDEF.toInt(), response.transactionId)
        assertEquals(0, requireNotNull(PtpIpOperationCodec.decodeResponse(hexBytes("012000000000"))).transactionId)
        assertEquals(-1, requireNotNull(PtpIpOperationCodec.decodeResponse(hexBytes("0120FFFFFFFF00000000"))).transactionId)
    }

    @Test
    fun everyTruncatedResponseIsSafeForNativeCaller() {
        val response = hexBytes("012044332211")
        for (length in 0 until response.size) {
            assertNull(PtpIpOperationCodec.decodeResponse(response.copyOf(length)))
        }
    }

    @Test
    fun dataPrefixDoesNotRequireOrInterpretMediaBytes() {
        assertEquals(4, PtpIpOperationCodec.DATA_PREFIX_SIZE)
        val prefix = hexBytes("FFFFFFFF")
        assertEquals(-1, requireNotNull(PtpIpOperationCodec.decodeDataHeader(prefix)).transactionId)
        assertEquals(-1, requireNotNull(PtpIpOperationCodec.decodeDataHeader(prefix + hexBytes("FFD8FFE1"))).transactionId)
        for (length in 0 until 4) assertNull(PtpIpOperationCodec.decodeDataHeader(prefix.copyOf(length)))
    }

    @Test
    fun nativeDeviceInfoUsesExistingGoldenDatasetAndRejectsEveryTruncation() {
        // Same captured fixed dataset as NikonDatasetParserTest, not bytes encoded by production.
        val payload = hexBytes(
            "6400EFCDAB8905A0033C5CB75E0000010003000000011028942894" +
                "01000000084002000000015067D000000000010000000138" +
                "064E0069006B006F006E000000055A002000330030000000" +
                "0431002E00300000000553004E003DD800DE0000",
        )
        val info = requireNotNull(PtpIpOperationCodec.decodeDeviceInfo(payload))
        assertEquals("Nikon", info.manufacturer)
        assertEquals("Z 30", info.model)
        assertEquals("SN😀", info.serial)
        assertEquals(parseDeviceInfo(payload), info)
        for (length in payload.indices) assertNull(PtpIpOperationCodec.decodeDeviceInfo(payload.copyOf(length)))
        assertNull(PtpIpOperationCodec.decodeDeviceInfo(hexBytes("64000A0000006400000000FFFFFFFF")))
    }
}
