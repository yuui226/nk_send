package com.ztransfer.catalog

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class CameraFileHeadSelectionTest {
    @Test
    fun emptyAndMissingHeadsDoNotInventAnIndex() {
        assertNull(selectNewestCameraFileHeadIndex<File>(emptyList()))
        assertNull(selectNewestCameraFileHeadIndex(listOf(null, null)))
        assertEquals(1, selectNewestCameraFileHeadIndex(listOf(null, file(2, "20260807T090000"))))
    }

    @Test
    fun newestDatedHeadWinsAcrossCards() {
        assertEquals(
            1,
            selectNewestCameraFileHeadIndex(
                listOf(file(1, "20260806T120000"), file(2, "20260807T090000")),
            ),
        )
    }

    @Test
    fun equalDatesKeepStableCardOrderInsteadOfComparingHandles() {
        assertEquals(
            0,
            selectNewestCameraFileHeadIndex(
                listOf(
                    file(0x091961BF, "20260807T090000"),
                    file(0x611961BD, "20260807T090000"),
                ),
            ),
        )
    }

    @Test
    fun missingDateIsReleasedFirstSoItCannotBlockThatCardsRemainingFiles() {
        assertEquals(
            1,
            selectNewestCameraFileHeadIndex(
                listOf(file(1, "20260807T090000"), file(2, null)),
            ),
        )
        assertEquals(
            0,
            selectNewestCameraFileHeadIndex(listOf(file(1, null), file(2, null))),
        )
    }

    private data class File(
        override val handle: Int,
        override val captureDate: String?,
    ) : CameraCatalogFile {
        override val fileName: String = "DSC_$handle.JPG"
        override val isProtected: Boolean = false
        override val storageIds: Set<Int> = emptySet()
        override val extension: String = ".jpg"
    }

    private fun file(handle: Int, captureDate: String?) = File(handle, captureDate)
}
