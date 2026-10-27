package com.ztransfer.viewmodel

import com.ztransfer.protocol.NikonCamera
import com.ztransfer.protocol.PtpConstants
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ExistingFileNameIndexTest {
    @org.junit.Test
    fun concurrentWritersReserveDifferentNamesAndIncompleteFilesAreNotReadable() {
        val index = ExistingFileNameIndex<Int>()
        val pool = java.util.concurrent.Executors.newFixedThreadPool(4)
        val suffix: (String, Int) -> String = { name, n -> "$name ($n)" }
        try {
            val names = (0 until 64).map {
                pool.submit<String> { index.reserveDisplayName("photo.jpg", suffix) }
            }.map { it.get(5, java.util.concurrent.TimeUnit.SECONDS) }
            org.junit.Assert.assertEquals(64, names.toSet().size)
            org.junit.Assert.assertNull(index.find("photo.jpg", 100))
            org.junit.Assert.assertTrue(index.containsDisplayName("PHOTO.JPG"))
            val original = names.first { it == "photo.jpg" }
            index.add(original, 100, 7)
            names.forEach(index::releaseDisplayName)
            org.junit.Assert.assertEquals(7, index.find(original, 100)?.value)
            org.junit.Assert.assertEquals("PHOTO.JPG (1)", index.reserveDisplayName("PHOTO.JPG", suffix))
        } finally { pool.shutdownNow() }
    }

    private fun file(name: String, size: Long) = NikonCamera.FileInfo(
        handle = 1,
        size = size,
        fileName = name,
        captureDate = null,
    )

    @Test
    fun exactNameWinsAndNormalizedCopyLookupDoesNotScanHistory() {
        val index = ExistingFileNameIndex<String>()
        repeat(10_000) { number ->
            index.add("OTHER_$number.JPG", number.toLong(), "other-$number")
        }
        index.add("DSC_0001 (2).JPG", 100L, "copy")
        index.add("DSC_0001.JPG", 100L, "exact")

        assertEquals("exact", index.find("DSC_0001.JPG", 100L)?.value)
        assertEquals("copy", index.find("dsc_0001.jpg", 100L)?.value)
    }

    @Test
    fun normalizedLookupStillRequiresTheCorrectKnownSize() {
        val index = ExistingFileNameIndex<String>()
        index.add("DSC_0001 (2).JPG", 100L, "copy")

        assertNull(index.find("DSC_0001.JPG", 99L))
        assertEquals(
            "copy",
            index.find("DSC_0001.JPG", PtpConstants.SIZE_UNKNOWN)?.value,
        )
    }

    @Test
    fun replacingAnEntryRemovesItsStaleSizeFromTheNormalizedBucket() {
        val index = ExistingFileNameIndex<String>()
        index.add("DSC_0001 (2).JPG", 100L, "old")
        index.add("DSC_0001 (2).JPG", 120L, "new")

        assertNull(index.find("DSC_0001.JPG", 100L))
        assertEquals("new", index.find("DSC_0001.JPG", 120L)?.value)
    }

    @Test
    fun exportedOriginalIndexUpdatesInPlaceAndDeduplicatesSizes() {
        val index = ExportedOriginalIndex()
        val original = file("DSC_0001.JPG", 100L)

        assertTrue(index.add("dsc_0001 (2).jpg", 100L))
        assertFalse(index.add("DSC_0001.JPG", 100L))
        assertTrue(index.contains(original))
        assertFalse(index.contains(original.copy(size = 99L)))
    }

    @Test
    fun exportedOriginalIndexKeepsRootAndDatedFoldersIndependent() {
        val original = file("DSC_0001.JPG", 100L).copy(captureDate = "20260817T120000")
        val rootIndex = ExportedOriginalIndex().apply {
            add(original.fileName, original.size)
        }
        val datedIndex = ExportedOriginalIndex().apply {
            add(original.fileName, original.size, "ZT2026-08-17")
        }

        assertTrue(isTransferredOriginal(original, rootIndex, organizeTransfersByDate = false))
        assertFalse(isTransferredOriginal(original, rootIndex, organizeTransfersByDate = true))
        assertFalse(isTransferredOriginal(original, datedIndex, organizeTransfersByDate = false))
        assertTrue(isTransferredOriginal(original, datedIndex, organizeTransfersByDate = true))
    }

    @Test
    fun datedLookupOnlyMatchesTheCaptureDateDestination() {
        val original = file("DSC_0001.JPG", 100L).copy(captureDate = "20260817T120000")
        val index = ExportedOriginalIndex().apply {
            add(original.fileName, original.size, "ZT2026-08-18")
        }

        assertFalse(isTransferredOriginal(original, index, organizeTransfersByDate = true))
    }
    @Test
    fun differentPrefixesShareOriginalLookupButKeepTypeSizeAndDirectory() {
        val names = ExistingFileNameIndex<String>().apply {
            add("DSC_9049 (2).JPG", 123L, "original")
        }
        assertEquals("original", names.find("Z30_9049.jpg", 123L)?.value)
        assertNull(names.find("Z30_9049.NEF", 123L))
        assertNull(names.find("Z30_9049.JPG", 124L))
        assertNull(names.find("Z30_9050.JPG", 123L))
        assertFalse(names.containsDisplayName("Z30_9049.JPG"))

        val exported = ExportedOriginalIndex().apply {
            add("DSC_9049.JPG", 123L, "ZT2026-09-29")
        }
        val apFile = file("Z30_9049.JPG", 123L)
        assertTrue(exported.contains(apFile, "ZT2026-09-29"))
        assertFalse(exported.contains(apFile))
        assertFalse(exported.contains(apFile.copy(size = 124L), "ZT2026-09-29"))
        assertFalse(exported.contains(apFile.copy(fileName = "Z30_9049.NEF"), "ZT2026-09-29"))
    }

    @Test
    fun videosShareSuffixButCropsAndNamesWithoutNumbersRemainSeparate() {
        val index = ExistingFileNameIndex<String>().apply {
            add("DSC_9053.MP4", 456L, "video")
            add("DSC_9049_crop.JPG", 123L, "crop")
            add("holiday.JPG", 123L, "photo")
        }
        assertEquals("video", index.find("Z30_9053.mp4", 456L)?.value)
        assertNull(index.find("Z30_9053.MOV", 456L))
        assertNull(index.find("Z30_9049.JPG", 123L))
        assertNull(index.find("trip.JPG", 123L))
        assertEquals("photo", index.find("HOLIDAY.jpg", 123L)?.value)
    }

    @Test
    fun shortDerivedNamesNeverStandInForTheCameraOriginal() {
        val suffixes = listOf("c", "f", "w", "e", "f_e", "w_e", "c_f_e")
        for (suffix in suffixes) {
            for (number in listOf("", " (1)", " (1000)")) {
                val name = "DSC_9049_$suffix$number.jpg"
                val index = ExistingFileNameIndex<String>().apply { add(name, 123L, "derived") }
                assertNull(name, index.find("DSC_9049.JPG", 123L))
                assertNull(name, index.find("Z30_9049.JPG", 123L))
                assertEquals("derived", index.find(name, 123L)?.value)

                val exported = ExportedOriginalIndex().apply { add(name, 123L) }
                assertFalse(name, exported.contains(file("Z30_9049.JPG", 123L)))
            }
        }
    }

    @Test
    fun verificationOnlyRunsForAnIndexedCandidateAndReusesAnUnchangedOriginal() {
        val index = ExistingFileNameIndex<String>()
        var checked = 0
        val verify: (IndexedExistingFile<String>) -> IndexedExistingFile<String>? = {
            checked++
            it
        }
        assertNull(index.findVerified("DSC_0001.JPG", 100, verify) { error("No stale entry") })
        assertEquals(0, checked)

        index.add("DSC_0001.JPG", 100, "original")
        assertEquals("original", index.findVerified("DSC_0001.JPG", 100, verify) {
            error("Valid file must stay indexed")
        }?.value)
        assertEquals(1, checked)
    }

    @Test
    fun deletedOriginalIsRemovedButAnExistingNumberedCopyCanStillSupplyIt() {
        val index = ExistingFileNameIndex<String>().apply {
            add("DSC_0001.JPG", 100, "deleted")
            add("DSC_0001 (1).JPG", 100, "surviving-copy")
        }
        val removed = mutableListOf<String>()
        val checked = mutableListOf<String>()
        val found = index.findVerified("DSC_0001.JPG", 100, verify = {
            checked += it.value
            it.takeUnless { candidate -> candidate.value == "deleted" }
        }, onInvalidated = { removed += it.value })

        assertEquals("surviving-copy", found?.value)
        assertEquals(listOf("deleted", "surviving-copy"), checked)
        assertEquals(listOf("deleted"), removed)
        assertFalse(index.containsDisplayName("DSC_0001.JPG"))
        assertTrue(index.containsDisplayName("DSC_0001 (1).JPG"))
    }

    @Test
    fun deletingAllOriginalCopiesLeavesEffectsAloneAndAllowsOriginalFilenameAgain() {
        val index = ExistingFileNameIndex<String>().apply {
            add("DSC_0001.JPG", 100, "deleted")
            add("DSC_0001 (1).JPG", 100, "also-deleted")
            add("DSC_0001_f_e.JPG", 100, "effect")
        }
        val removed = mutableListOf<String>()
        assertNull(index.findVerified("Z30_0001.JPG", 100, verify = { null },
            onInvalidated = { removed += it.value }))

        assertEquals(setOf("deleted", "also-deleted"), removed.toSet())
        assertEquals("effect", index.find("DSC_0001_f_e.JPG", 100)?.value)
        assertEquals("DSC_0001.JPG", index.reserveDisplayName("DSC_0001.JPG") { _, _ ->
            error("Deleted original name should be available")
        })
    }

    @Test
    fun editedFileKeepsItsNameOccupiedAndNoLongerSkipsTheOriginalSize() {
        val index = ExistingFileNameIndex<String>().apply { add("DSC_0001.JPG", 100, "edited") }
        val removed = mutableListOf<Long>()

        assertNull(index.findVerified("DSC_0001.JPG", 100,
            verify = { it.copy(size = 200) }, onInvalidated = { removed += it.size }))
        assertEquals(listOf(100L), removed)
        assertEquals(200L, index.find("DSC_0001.JPG", 200)?.size)
        assertEquals("DSC_0001 (1).JPG", index.reserveDisplayName("DSC_0001.JPG") { _, n ->
            "DSC_0001 ($n).JPG"
        })
    }

    @Test
    fun renamedFileKeepsItsActualNameAndReleasesTheOldName() {
        val index = ExistingFileNameIndex<String>().apply { add("DSC_0001.JPG", 100, "renamed") }
        assertNull(index.findVerified("DSC_0001.JPG", 100,
            verify = { it.copy(displayName = "holiday.JPG") }, onInvalidated = {}))

        assertFalse(index.containsDisplayName("DSC_0001.JPG"))
        assertTrue(index.containsDisplayName("holiday.JPG"))
        assertEquals("renamed", index.find("holiday.JPG", 100)?.value)
    }

    @Test
    fun providerFailureDoesNotRemoveTheCandidateOrAnyOtherOriginal() {
        val index = ExistingFileNameIndex<String>().apply {
            add("DSC_0001.JPG", 100, "original")
            add("DSC_0002.JPG", 200, "other")
        }
        val failure = SecurityException("Permission unavailable")
        try {
            index.findVerified("DSC_0001.JPG", 100, verify = { throw failure },
                onInvalidated = { error("Provider failure is not proof of deletion") })
            error("Expected provider failure")
        } catch (actual: SecurityException) {
            assertTrue(actual === failure)
        }
        assertEquals("original", index.find("DSC_0001.JPG", 100)?.value)
        assertEquals("other", index.find("DSC_0002.JPG", 200)?.value)
    }

    @Test
    fun delayedMissingResultCannotRemoveANewerPublicationOfTheSameName() {
        val index = ExistingFileNameIndex<String>().apply { add("DSC_0001.JPG", 100, "old") }
        val removed = mutableListOf<String>()
        val found = index.findVerified("DSC_0001.JPG", 100, verify = {
            if (it.value == "old") {
                index.add("DSC_0001.JPG", 100, "new")
                null
            } else it
        }, onInvalidated = { removed += it.value })

        assertEquals("new", found?.value)
        assertTrue(removed.isEmpty())
    }

    @Test
    fun removingOneCaseSensitiveDocumentPreservesOtherSpellingAndActiveReservations() {
        val index = ExistingFileNameIndex<String>()
        val reserved = index.reserveDisplayName("DSC_0001.JPG") { name, n -> "$name ($n)" }
        index.add("DSC_0001.JPG", 100, "upper")
        index.add("dsc_0001.jpg", 100, "lower")

        assertTrue(index.remove(IndexedExistingFile("DSC_0001.JPG", 100, "upper")))
        assertTrue(index.containsDisplayName("DSC_0001.JPG"))
        assertTrue(index.remove(IndexedExistingFile("dsc_0001.jpg", 100, "lower")))
        assertTrue(index.containsDisplayName("DSC_0001.JPG"))
        index.releaseDisplayName(reserved)
        assertFalse(index.containsDisplayName("DSC_0001.JPG"))
    }

    @Test
    fun exportedIndexRemovalRequiresExactUriAndPreservesOtherSizesAndDestinations() {
        val index = ExportedOriginalIndex().apply {
            add("DSC_0001.JPG", 100, uriString = "new")
            add("DSC_0001.JPG", 200, uriString = "other-size")
            add("DSC_0001.JPG", 100, "ZT2026-11-02", uriString = "other-day")
            add("DSC_0002.JPG", 100, uriString = "other-photo")
        }

        assertFalse(index.remove("DSC_0001.JPG", 100, uriString = "old"))
        assertTrue(index.contains(file("DSC_0001.JPG", 100)))
        assertTrue(index.remove("Z30_0001.JPG", 100, uriString = "new"))
        assertFalse(index.contains(file("DSC_0001.JPG", 100)))
        assertTrue(index.contains(file("DSC_0001.JPG", 200)))
        assertTrue(index.contains(file("DSC_0001.JPG", 100), "ZT2026-11-02"))
        assertTrue(index.contains(file("DSC_0002.JPG", 100)))
    }

    @Test
    fun removingLastExportEntryDoesNotMatchUnknownSizeThroughAnEmptyBucket() {
        val index = ExportedOriginalIndex().apply {
            add("DSC_0001.MP4", 100, uriString = "video")
        }
        val unknown = file("DSC_0001.MP4", PtpConstants.SIZE_UNKNOWN)
        assertTrue(index.contains(unknown))

        assertTrue(index.remove("DSC_0001.MP4", 100, uriString = "video"))
        assertFalse(index.contains(unknown))
        assertFalse(index.contains(file("DSC_0001.MP4", 100)))
        assertTrue(index.add("DSC_0001.MP4", 200, uriString = "new-video"))
        assertTrue(index.contains(unknown))
    }
}
