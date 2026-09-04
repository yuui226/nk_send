package com.ztransfer.viewmodel

import com.ztransfer.protocol.NikonCamera
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class CameraStorageTest {
    @Test
    fun `backup duplicate keeps membership of both cards`() {
        val card1 = file(handle = 1, storageId = 0x00010001)
        val card2 = file(handle = 2, storageId = 0x00020001)
        val merged = mergeStorageMembership(card1, card2)

        assertEquals(setOf(0x00010001, 0x00020001), merged.storageIds)
        assertEquals(card1.handle, merged.handle)
        assertSame(merged, mergeStorageMembership(merged, card2))
    }

    private fun file(handle: Int, storageId: Int) = NikonCamera.FileInfo(
        handle = handle,
        size = 1024L,
        fileName = "DSC_0001.JPG",
        captureDate = "20260806T120000",
        storageIds = setOf(storageId),
    )
}
