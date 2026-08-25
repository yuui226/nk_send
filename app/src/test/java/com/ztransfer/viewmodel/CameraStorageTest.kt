package com.ztransfer.viewmodel

import com.ztransfer.protocol.NikonCamera
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class CameraStorageTest {
    @Test
    fun `physical storage id maps to the real card slot`() {
        assertEquals(
            mapOf(1 to setOf(0x00010001), 2 to setOf(0x00020001)),
            storageIdsBySlot(listOf(0x00020001, 0x00010001)),
        )
        assertEquals(
            mapOf(2 to setOf(0x00020001)),
            storageIdsBySlot(listOf(0x00020001)),
        )
    }

    @Test
    fun `nonstandard storage ids get stable fallback slots`() {
        assertEquals(
            mapOf(1 to setOf(0x00030001), 2 to setOf(0x00040001)),
            storageIdsBySlot(listOf(0x00040001, 0x00030001)),
        )
    }

    @Test
    fun `logical partitions stay on the same physical card`() {
        assertEquals(
            mapOf(1 to setOf(0x00010001, 0x00010002), 2 to setOf(0x00020001)),
            storageIdsBySlot(listOf(0x00010002, 0x00020001, 0x00010001)),
        )
    }

    @Test
    fun `low word slot ids are supported as a fallback`() {
        assertEquals(
            mapOf(1 to setOf(0x00000001), 2 to setOf(0x00000002)),
            storageIdsBySlot(listOf(0x00000002, 0x00000001)),
        )
    }

    @Test
    fun `backup duplicate keeps membership of both cards`() {
        val card1 = file(handle = 1, storageId = 0x00010001)
        val card2 = file(handle = 2, storageId = 0x00020001)
        val merged = mergeStorageMembership(card1, card2)

        assertEquals(setOf(0x00010001, 0x00020001), merged.storageIds)
        assertEquals(card1.handle, merged.handle)
        assertSame(merged, mergeStorageMembership(merged, card2))
    }

    @Test
    fun `direct sta disjoint handle sets preserve exact card membership`() {
        val layout = analyzeStaDirectStorageLayout(
            listOf(
                0x00010001 to listOf(11, 12),
                0x00020001 to listOf(21, 22),
            ),
        )

        assertEquals(setOf(0x00010001), layout.storageIdsByHandle[11])
        assertEquals(setOf(0x00020001), layout.storageIdsByHandle[22])
        assertEquals(listOf(0x00010001, 0x00020001), layout.filterStorageIds)
        assertEquals(0, layout.crossSlotOverlapCount)
    }

    @Test
    fun `direct sta aggregate responses disable misleading cross-slot filter`() {
        val layout = analyzeStaDirectStorageLayout(
            listOf(
                0x00010001 to listOf(11, 12, 13),
                0x00020001 to listOf(11, 12, 13),
            ),
        )

        assertEquals(emptyMap<Int, Set<Int>>(), layout.storageIdsByHandle)
        assertEquals(emptyList<Int>(), layout.filterStorageIds)
        assertEquals(3, layout.crossSlotOverlapCount)
    }

    @Test
    fun `overlapping logical stores on one physical card remain usable`() {
        val layout = analyzeStaDirectStorageLayout(
            listOf(
                0x00010001 to listOf(11, 12),
                0x00010002 to listOf(12, 13),
            ),
        )

        assertEquals(setOf(0x00010001, 0x00010002), layout.storageIdsByHandle[12])
        assertEquals(listOf(0x00010001, 0x00010002), layout.filterStorageIds)
        assertEquals(0, layout.crossSlotOverlapCount)
    }

    private fun file(handle: Int, storageId: Int) = NikonCamera.FileInfo(
        handle = handle,
        size = 1024L,
        fileName = "DSC_0001.JPG",
        captureDate = "20260806T120000",
        storageIds = setOf(storageId),
    )
}
