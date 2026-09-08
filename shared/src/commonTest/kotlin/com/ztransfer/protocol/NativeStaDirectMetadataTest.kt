package com.ztransfer.protocol

import com.ztransfer.test.hexBytes
import kotlin.test.*

class NativeStaDirectMetadataTest {
    private fun ptp(value: String) = byteArrayOf((value.length + 1).toByte()) +
        value.flatMap { listOf(it.code.toByte(), (it.code ushr 8).toByte()) }.toByteArray() + byteArrayOf(0, 0)

    @Test fun boundedHeaderKeepsAndroidFallbackNameAndDoesNotClaimStorageOrProtection() {
        val bytes = hexBytes("FFD8FFE1")
        val original = bytes.copyOf()
        val info = assertNotNull(NativeStaDirectMetadata().headerInfo(0x291961f5, 4000, bytes, "2026:08:24 20:45:40", 0))
        assertEquals("ZTransfer_20260824204540_291961F5.jpg", info.fileName)
        assertEquals("20260824T204540", info.captureDate)
        assertEquals(0, info.storageId); assertFalse(info.isProtected); assertFalse(info.isAssociation)
        assertContentEquals(original, bytes)
    }
    @Test fun nonLatinProtocolNameBeatsEmbeddedNamesAndRoundTripsWithoutTransliteration() {
        val model = NativeStaDirectMetadata()
        assertEquals("照片42.JPG", model.loadName(7, ptp("照片42.JPG")))
        val info = assertNotNull(model.headerInfo(7, 900, hexBytes("FFD8") + "DSC_1234.JPG".encodeToByteArray(), null, 0x10001))
        assertEquals("照片42.JPG", info.fileName)
    }
    @Test fun embeddedScannerKeepsItsOriginalColonAndLongStemBehavior() {
        val model = NativeStaDirectMetadata()
        assertEquals("01.JPG", model.headerInfo(7, 900, hexBytes("FFD8") + "BAD:01.JPG".encodeToByteArray(), null, 0)?.fileName)
        val raw = "X".repeat(35) + "1.JPG"
        assertEquals("X".repeat(31) + "1.JPG", model.headerInfo(8, 900, hexBytes("FFD8") + raw.encodeToByteArray(), null, 0)?.fileName)
    }
    @Test fun exactIndexAndKnownNameAvoidHeaderButMalformedIndexCannotEraseGoodFields() {
        val model = NativeStaDirectMetadata()
        val handle = 0x291961f5
        model.loadName(handle, ptp("DSC_8693.JPG"))
        assertNull(model.indexedInfo(handle, 1000, 0))
        model.loadDates(hexBytes("6400000001000000F56119290000000000282D141808EA07"))
        model.loadDates(byteArrayOf(1, 2, 3))
        assertEquals("20260824T204540", model.indexedInfo(handle, 1000, 0)?.captureDate)
        assertNull(model.indexedInfo(handle, 0, 0))
        model.invalidate(handle); assertNull(model.indexedInfo(handle, 1000, 0)); assertNull(model.name(handle))
    }
    @Test fun unsupportedExtensionAndEmptyHeaderCannotProduceIndexedMedia() {
        val model = NativeStaDirectMetadata()
        assertNull(model.headerInfo(7, 10, byteArrayOf(), null, 0))
        assertNull(model.headerInfo(7, 0, hexBytes("FFD8"), null, 0))
        assertNull(model.indexedInfo(7, 10, 0))
        model.loadName(7, ptp("DSC_0007.JPG")); model.clear(); assertNull(model.name(7))
    }
    @Test fun extractedHeaderBrandClassificationPreservesNonAsciiBrandBehavior() {
        for (byte in 0..255) {
            val header = byteArrayOf(0, 0, 0, 16) + "ftyp".encodeToByteArray() + byteArrayOf(byte.toByte(), 116, 32, 32)
            assertEquals(if (byte == 'q'.code) ".mov" else ".mp4", staDirectObjectExtension(header))
        }
        assertEquals(".nef", staDirectObjectExtension(hexBytes("49492A00")))
        assertEquals(".nef", staDirectObjectExtension(hexBytes("4D4D002A")))
        assertEquals(".bin", staDirectObjectExtension(byteArrayOf()))
    }
}
