package com.ztransfer.protocol

import com.ztransfer.test.hexBytes
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PtpObjectInfoParserTest {
    @Test
    fun completeObjectInfoMatchesFixedUnicodeDataset() {
        val parsed = requireNotNull(
            parsePtpObjectInfo(
                handle = 7,
                data = hexBytes(
                    "0100010001B10080FFFFFFFF01380403020140010000F00000004020000080150000" +
                        "0E000000000000000000000000007856341209677147723DD800DE2E004E00450046000000" +
                        "1032003000320036003000390030003400540031003500300036003000370000000000",
                ),
            ),
        )

        assertEquals(7, parsed.handle)
        assertEquals(0x00010001, parsed.storageId)
        assertEquals(0xB101, parsed.objectFormat)
        assertEquals(0xFFFFFFFFL, parsed.size)
        assertEquals("照片😀.NEF", parsed.fileName)
        assertEquals("20260904T150607", parsed.captureDate)
        assertTrue(parsed.isProtected)
        assertFalse(parsed.isAssociation)
        assertTrue(parsed.identityComplete)
    }

    @Test
    fun fixedPrefixAndAssociationBoundariesStayCompatible() {
        assertNull(parsePtpObjectInfo(1, ByteArray(52)))

        val folder = ByteArray(53)
        folder[4] = 0x01
        folder[5] = 0x30
        val parsedFolder = requireNotNull(parsePtpObjectInfo(1, folder))
        assertTrue(parsedFolder.isAssociation)
        assertTrue(parsedFolder.identityComplete)
        assertNull(parsedFolder.fileName)

        val noStorage = objectInfoPrefix(storageId = 0, protection = 2)
        val parsedNoStorage = requireNotNull(parsePtpObjectInfo(2, noStorage))
        assertEquals(0, parsedNoStorage.storageId)
        assertTrue(parsedNoStorage.isProtected)
        assertFalse(parsedNoStorage.identityComplete)

        assertEquals(-1, requireNotNull(parsePtpObjectInfo(3, objectInfoPrefix(-1))).storageId)
    }

    @Test
    fun cacheIdentityCompleteAndIncompleteCasesStayFixed() {
        val complete = objectInfoPayload("DSC_0007.JPG", "20260812T120000")
        assertEquals(
            ParsedObjectCacheIdentity("DSC_0007.JPG", "20260812T120000", true),
            parseObjectCacheIdentity(7, ".JPG", complete),
        )
        assertEquals(
            ParsedObjectCacheIdentity("DSC_0007.JPG", null, true),
            parseObjectCacheIdentity(7, ".JPG", objectInfoPayload("DSC_0007.JPG", null)),
        )

        val truncatedName = ByteArray(55).also { it[52] = 8 }
        assertEquals(
            ParsedObjectCacheIdentity("DSC_0007.JPG", null, false),
            parseObjectCacheIdentity(7, ".JPG", truncatedName),
        )
        assertFalse(parseObjectCacheIdentity(7, ".JPG", complete.copyOf(complete.size - 4)).complete)

        val unterminatedDate = complete.copyOf().also { it[it.lastIndex] = 'X'.code.toByte() }
        assertFalse(parseObjectCacheIdentity(7, ".JPG", unterminatedDate).complete)

        val shortDate = objectInfoPayload("DSC_0007.JPG", "1234567")
        assertFalse(parseObjectCacheIdentity(7, ".JPG", shortDate).complete)

        val nullOnlyDate = objectInfoPayload("DSC_0007.JPG", "")
        assertFalse(parseObjectCacheIdentity(7, ".JPG", nullOnlyDate).complete)

        val uncheckedDate = objectInfoPayload("DSC_0007.JPG", "abcdefgh")
        assertEquals(
            "abcdefgh",
            parseObjectCacheIdentity(7, ".JPG", uncheckedDate).captureDate,
        )
    }

    @Test
    fun standaloneFilenameAndPropertyListKeepValidationRules() {
        val path = ptpString("folder\\DSC_0001.JPG")
        assertEquals("DSC_0001.JPG", parsePtpObjectFileName(path)?.first)
        assertNull(parsePtpObjectFileName(ptpString("BAD:0001.JPG")))
        assertNull(parsePtpObjectFileName(path.copyOf(path.size - 1)))

        val propertyList = hexBytes(
            "010000004433221107DCFFFF0D" +
                "4400530043005F0030003000300031002E004A00500047000000",
        )
        assertEquals(
            mapOf(0x11223344 to "DSC_0001.JPG"),
            parseObjectFileNamePropertyList(propertyList),
        )
        assertEquals(
            mapOf(0x11223344 to "DSC_0001.JPG"),
            parseObjectFileNamePropertyList(propertyList + byteArrayOf(0x7F)),
        )
        assertEquals(emptyMap(), parseObjectFileNamePropertyList(propertyList.copyOf(propertyList.size - 1)))
        assertEquals(
            emptyMap(),
            parseObjectFileNamePropertyList(propertyList.copyOf().also { it[8] = 0x08 }),
        )
    }

    private fun objectInfoPrefix(storageId: Int = 1, protection: Int = 0): ByteArray =
        ByteArray(54).also { bytes ->
            repeat(4) { index -> bytes[index] = (storageId ushr (index * 8)).toByte() }
            bytes[4] = 0x01
            bytes[5] = 0x38
            bytes[6] = protection.toByte()
            bytes[52] = 0
            bytes[53] = 0
        }

    private fun objectInfoPayload(fileName: String, captureDate: String?): ByteArray {
        val encodedName = ptpString(fileName)
        val encodedDate = captureDate?.let(::ptpString) ?: byteArrayOf(0)
        return ByteArray(52) + encodedName + encodedDate
    }

    private fun ptpString(value: String): ByteArray =
        ByteArray(1 + (value.length + 1) * 2).also { bytes ->
            bytes[0] = (value.length + 1).toByte()
            value.forEachIndexed { index, character ->
                bytes[1 + index * 2] = character.code.toByte()
                bytes[2 + index * 2] = (character.code ushr 8).toByte()
            }
        }

}
