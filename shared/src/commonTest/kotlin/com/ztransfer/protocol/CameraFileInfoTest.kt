package com.ztransfer.protocol

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CameraFileInfoTest {
    @Test
    fun preservesUnsignedHandleBitsLargeSizeAndMultiStorageMetadata() {
        val file = CameraFileInfo(
            handle = -2,
            size = 0x1_0000_0000L,
            fileName = "DSC_0001.JpG",
            captureDate = "20260904T203223",
            isProtected = true,
            storageIds = setOf(0x0001_0001, 0x0002_0001),
        )

        assertEquals(-2, file.handle)
        assertEquals(0x1_0000_0000L, file.size)
        assertEquals(".jpg", file.extension)
        assertTrue(file.isProtected)
        assertEquals(setOf(0x0001_0001, 0x0002_0001), file.storageIds)
    }

    @Test
    fun copyRecomputesExtensionWhenFileNameChanges() {
        val jpeg = CameraFileInfo(
            handle = 1,
            size = 100L,
            fileName = "DSC_0001.JPG",
            captureDate = null,
        )

        assertEquals(".mov", jpeg.copy(fileName = "DSC_0001.MOV").extension)
        assertFalse(jpeg.isProtected)
        assertTrue(jpeg.storageIds.isEmpty())
    }
}
