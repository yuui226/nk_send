package com.ztransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MultiStorageFileOrderTest {
    @Test
    fun emptyHeadsAreIgnoredWithoutInventingAnIndex() {
        assertNull(selectNewestFileHeadIndex(emptyList()))
        assertNull(selectNewestFileHeadIndex(listOf(null, null)))
        assertEquals(
            1,
            selectNewestFileHeadIndex(listOf(null, file(2, "20260807T090000"))),
        )
    }

    @Test
    fun newestDatedHeadWinsAcrossCards() {
        assertEquals(
            1,
            selectNewestFileHeadIndex(
                listOf(
                    file(1, "20260806T120000"),
                    file(2, "20260807T090000"),
                )
            ),
        )
    }

    @Test
    fun equalDatesKeepStableStorageOrderInsteadOfComparingHandles() {
        assertEquals(
            0,
            selectNewestFileHeadIndex(
                listOf(
                    file(0x091961BF, "20260807T090000"),
                    file(0x611961BD, "20260807T090000"),
                )
            ),
        )
    }

    @Test
    fun missingDateIsReleasedFirstSoItCannotBlockThatCardsRemainingFiles() {
        assertEquals(
            1,
            selectNewestFileHeadIndex(
                listOf(
                    file(1, "20260807T090000"),
                    file(2, null),
                )
            ),
        )
    }

    @Test
    fun twoMissingDatesKeepStableStorageOrder() {
        assertEquals(
            0,
            selectNewestFileHeadIndex(listOf(file(1, null), file(2, null))),
        )
    }

    private fun file(handle: Int, captureDate: String?) = NikonCamera.FileInfo(
        handle = handle,
        size = 1024L,
        fileName = "DSC_$handle.JPG",
        captureDate = captureDate,
    )
}
