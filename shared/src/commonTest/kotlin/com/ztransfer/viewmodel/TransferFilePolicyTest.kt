package com.ztransfer.viewmodel

import com.ztransfer.protocol.PtpConstants
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class TransferFilePolicyTest {
    @Test
    fun copySuffixNormalizationPreservesTheExistingJvmRegexBehavior() {
        assertEquals("DSC_0001.JPG", exportedOriginalBaseName("DSC_0001 (2).JPG"))
        assertEquals("README", exportedOriginalBaseName("README (3)"))
        assertEquals("archive.tar.gz", exportedOriginalBaseName("archive.tar (2).gz"))
        assertEquals("a.jpg", exportedOriginalBaseName("a (1).jpg (2)"))
        assertEquals("a\n", exportedOriginalBaseName("a (1)\n"))
        assertEquals("a\r\n", exportedOriginalBaseName("a (1)\r\n"))
        assertEquals("a\u2028", exportedOriginalBaseName("a (1)\u2028"))
        assertEquals("DSC(2).JPG", exportedOriginalBaseName("DSC(2).JPG"))
        assertEquals("DSC (x).JPG", exportedOriginalBaseName("DSC (x).JPG"))
        assertEquals("DSC (２).JPG", exportedOriginalBaseName("DSC (２).JPG"))
        assertEquals("archive (2).tar.gz", exportedOriginalBaseName("archive (2).tar.gz"))
    }

    @Test
    fun directoryKeysUseLocaleIndependentCaseFolding() {
        assertEquals("dsc_0001.jpg", transferDirectoryLookupKey("DSC_0001 (2).JPG"))
        assertEquals("ii\u0307ıß.jpg", transferDirectoryLookupKey("Iİıẞ.JPG"))
        assertEquals("zt2026-08-17", transferDestinationLookupKey("ZT2026-08-17"))
        assertEquals("\u0000root", transferDestinationLookupKey(null))
    }

    @Test
    fun exactNameWinsAndNormalizedCopyLookupDoesNotScanHistory() {
        val index = ExistingFileNameIndexCore<String>()
        repeat(10_000) { number ->
            index.add("OTHER_$number.JPG", number.toLong(), "other-$number")
        }
        index.add("DSC_0001 (2).JPG", 100L, "copy")
        index.add("DSC_0001.JPG", 100L, "exact")

        assertEquals("exact", index.find("DSC_0001.JPG", 100L)?.value)
        assertEquals("copy", index.find("dsc_0001.jpg", 100L)?.value)
        assertTrue(index.containsDisplayName("DSC_0001.JPG"))
        assertFalse(index.containsDisplayName("dsc_0001.jpg"))
    }

    @Test
    fun normalizedLookupRetainsExactKnownAndUnknownSizeRules() {
        val index = ExistingFileNameIndexCore<String>()
        index.add("DSC_0001.JPG", 99L, "wrong-exact")
        index.add("DSC_0001 (2).JPG", 100L, "copy")

        assertEquals("copy", index.find("DSC_0001.JPG", 100L)?.value)
        assertEquals("wrong-exact", index.find("DSC_0001.JPG", PtpConstants.SIZE_UNKNOWN)?.value)
        assertNull(index.find("DSC_0001.JPG", 0L))
        assertTrue(matchesExistingFileSize(-1L, 100L))
        assertTrue(matchesExistingFileSize(100L, PtpConstants.SIZE_UNKNOWN))
        assertFalse(matchesExistingFileSize(100L, 0L))
        assertTrue(matchesExistingFileSize(0L, 0L))
    }

    @Test
    fun replacingAnEntryRemovesItsStaleSizeFromTheNormalizedBucket() {
        val index = ExistingFileNameIndexCore<String>()
        index.add("DSC_0001 (2).JPG", 100L, "old")
        index.add("DSC_0001 (2).JPG", 120L, "new")

        assertNull(index.find("DSC_0001.JPG", 100L))
        assertEquals("new", index.find("DSC_0001.JPG", 120L)?.value)
        assertEquals(listOf("new"), index.entries().map { it.value })
    }

    @Test
    fun datedDestinationUsesCaptureDayOrTheQueuedFallbackDay() {
        assertEquals("ZT2026-08-17", transferDateFolderName("20260817T142530", 20260321))
        assertEquals("ZT2026-03-21", transferDateFolderName(null, 20260321))
        assertEquals("ZT2026-03-21", transferDateFolderName("20260231T120000", 20260321))
        assertEquals("ZT0000-02-29", transferDateFolderName("00000229T120000", 20260321))
        assertEquals("ZT2026-03-21", transferDateFolderName("00000230T120000", 20260321))
        assertNull(transferDestinationFolderName("20260817T142530", false, 20260321))
        assertEquals(
            "ZT2026-08-17",
            transferDestinationFolderName("20260817T142530", true, 20260321),
        )
        assertTrue(isDatedTransferFolderName("ZT2026-08-17"))
        assertTrue(isDatedTransferFolderName("ZT2026-99-99"))
        assertFalse(isDatedTransferFolderName("ZT２０２６-08-17"))
        assertFalse(isDatedTransferFolderName("ZT2026-8-17"))
    }

    @Test
    fun automaticTransferIdentityKeepsItsNullableStringEncoding() {
        assertEquals(
            "DSC_0001.JPG|100|null",
            automaticTransferFileIdentity("DSC_0001.JPG", 100L, null),
        )
        assertEquals(
            "DSC_0001.JPG|100|20260817T142530",
            automaticTransferFileIdentity("DSC_0001.JPG", 100L, "20260817T142530"),
        )
    }

    @Test
    fun mimeMappingKeepsTheExistingCaseInsensitiveExtensions() {
        assertEquals("image/jpeg", transferMimeType("DSC_0001.JPG"))
        assertEquals("image/jpeg", transferMimeType("DSC_0001.jpeg"))
        assertEquals("image/png", transferMimeType("image.PnG"))
        assertEquals("image/x-nikon-nef", transferMimeType("DSC_0001.NEF"))
        assertEquals("video/quicktime", transferMimeType("clip.MOV"))
        assertEquals("video/mp4", transferMimeType("clip.mp4"))
        assertEquals("video/x-msvideo", transferMimeType("clip.AVI"))
        assertEquals("application/octet-stream", transferMimeType("README"))
        assertEquals("application/octet-stream", transferMimeType("file.raw"))
    }

    @Test
    fun partIdentityAndNamePreserveLegacySanitizing() {
        assertEquals("100.20260817T142530", transferPartIdentityToken(100L, "20260817T142530"))
        assertEquals("100.0", transferPartIdentityToken(100L, null))
        assertEquals("1.202608171425", transferPartIdentityToken(-1L, "2026:08-17 14_25"))
        assertEquals(
            "4294967295.0",
            transferPartIdentityToken(PtpConstants.SIZE_UNKNOWN, null),
        )
        assertEquals(
            ".nkpart_100.0_DSC_0001.JPG",
            transferPartFileName("DSC_0001.JPG", 100L, null),
        )
    }

    @Test
    fun partParserSplitsOnlyTheFirstUnderscoreAndIgnoresMalformedNames() {
        assertEquals(
            TransferPartName("100.0", "DSC_0001.JPG"),
            parseTransferPartFileName(".nkpart_100.0_DSC_0001.JPG"),
        )
        assertEquals(
            TransferPartName("DSC", "0001.JPG"),
            parseTransferPartFileName(".nkpart_DSC_0001.JPG"),
        )
        assertNull(parseTransferPartFileName("DSC_0001.JPG"))
        assertNull(parseTransferPartFileName(".NKPART_100.0_DSC_0001.JPG"))
        assertNull(parseTransferPartFileName(".nkpart__DSC_0001.JPG"))
        assertNull(parseTransferPartFileName(".nkpart_100.0_"))
        assertNull(parseTransferPartFileName(".nkpart_100.0"))
    }

    @Test
    fun numberedOriginalNamesKeepTheLastExtensionRules() {
        assertEquals("DSC (2).NEF", suffixedTransferFileName("DSC.NEF", 2))
        assertEquals("README (2)", suffixedTransferFileName("README", 2))
        assertEquals(".nomedia (2)", suffixedTransferFileName(".nomedia", 2))
        assertEquals("archive.tar (2).gz", suffixedTransferFileName("archive.tar.gz", 2))
        assertEquals("name (2).", suffixedTransferFileName("name.", 2))
    }

    @Test
    fun originalFallbackCopyRequiresExactLength() {
        assertTrue(isOriginalFileCopyComplete(100L, 100L))
        assertFalse(isOriginalFileCopyComplete(99L, 100L))
        assertFalse(isOriginalFileCopyComplete(101L, 100L))
        assertTrue(isOriginalFileCopyComplete(0L, 0L))
        assertFalse(isOriginalFileCopyComplete(1L, 0L))
    }
}
