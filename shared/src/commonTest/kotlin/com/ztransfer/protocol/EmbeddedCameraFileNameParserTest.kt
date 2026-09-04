package com.ztransfer.protocol

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class EmbeddedCameraFileNameParserTest {
    @Test
    fun findsPtpStringAtItsWireOffset() {
        val data = byteArrayOf(1, 2) + ptpString("/DCIM/100NIKON/DSC_0123.JPG")

        assertEquals(
            listOf(EmbeddedCameraFileName(2, "DSC_0123.JPG", "ptp-string")),
            findEmbeddedCameraFileNames(data),
        )
        assertTrue(findEmbeddedCameraFileNames(data, includePtpStrings = false).isEmpty())
    }

    @Test
    fun findsPlainAsciiNamesInOrderAndKeepsSeparateOccurrences() {
        val data = "xx DSC_0001.JPG yy DSC_0001.JPG zz A9.NEF".encodeToByteArray()

        assertEquals(
            listOf(
                EmbeddedCameraFileName(3, "DSC_0001.JPG", "ascii"),
                EmbeddedCameraFileName(19, "DSC_0001.JPG", "ascii"),
                EmbeddedCameraFileName(35, "A9.NEF", "ascii"),
            ),
            findEmbeddedCameraFileNames(data, includePtpStrings = false),
        )
    }

    @Test
    fun preservesAsciiSeparatorAndThirtyTwoCharacterWindowBehavior() {
        val data = (
            "NO_DIGITS.JPG BAD:01.JPG DSC_0001.BIN " +
                "A234567890123456789012345678901234.JPG"
            ).encodeToByteArray()
        assertEquals(
            listOf(
                EmbeddedCameraFileName(18, "01.JPG", "ascii"),
                EmbeddedCameraFileName(40, "34567890123456789012345678901234.JPG", "ascii"),
            ),
            findEmbeddedCameraFileNames(data, includePtpStrings = false),
        )

        val truncated = ptpString("DSC_9999.JPG").copyOf(10)
        assertTrue(findEmbeddedCameraFileNames(truncated).isEmpty())
        assertTrue(findEmbeddedCameraFileNames(ptpString("BAD:01.JPG")).isEmpty())
    }

    private fun ptpString(value: String): ByteArray = ByteArray(1 + (value.length + 1) * 2).also {
        it[0] = (value.length + 1).toByte()
        value.forEachIndexed { index, character ->
            it[1 + index * 2] = character.code.toByte()
            it[2 + index * 2] = (character.code ushr 8).toByte()
        }
    }
}
