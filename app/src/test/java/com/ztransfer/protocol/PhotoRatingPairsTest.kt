package com.ztransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

class PhotoRatingPairsTest {
    private fun file(handle: Int, name: String, date: String? = "20260929T120000", card: Int = 1) =
        NikonCamera.FileInfo(handle, 100, name, date, storageIds = setOf(card))

    @Test fun uniquePairUsesJpegEvenWhenRawComesFirst() {
        val raw = file(1, "Z30_9049.NEF")
        val jpg = file(2, "z30_9049.jpg")
        val sources = photoRatingSources(listOf(raw, jpg))
        assertEquals(jpg, sources[1])
        assertEquals(jpg, sources[2])
    }

    @Test fun uniquePairAlsoProjectsJpegRatingToNrw() {
        val raw = file(1, "Z30_9049.NRW")
        val jpg = file(2, "Z30_9049.JPG")
        assertEquals(jpg, photoRatingSources(listOf(raw, jpg))[1])
    }

    @Test fun unmatchedDifferentCardDateOrAmbiguousRawStaysIndependent() {
        val raw = file(1, "Z30_9049.NEF")
        for (others in listOf(emptyList(), listOf(file(2, "Z30_9049.JPG", card = 2)),
            listOf(file(2, "Z30_9049.JPG", date = "20260928T120000")),
            listOf(file(2, "Z30_9049.JPG"), file(3, "Z30_9049.JPEG")))) {
            assertEquals(raw, photoRatingSources(listOf(raw) + others)[1])
        }
    }

    @Test fun lateJpegChangesSourceAndRemovalRestoresRaw() {
        val raw = file(1, "Z30_9049.NEF", date = null)
        val jpg = file(2, "Z30_9049.JPG")
        assertEquals(raw, photoRatingSources(listOf(raw))[1])
        assertEquals(jpg, photoRatingSources(listOf(raw, jpg))[1])
        assertEquals(raw, photoRatingSources(listOf(raw))[1])
    }
}
