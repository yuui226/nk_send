package com.ztransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

class FileInfoExtensionTest {
    @Test
    fun `extension is normalized once from filename`() {
        assertEquals(".jpg", file("DSC_0001.JPG").extension)
        assertEquals(".nef", file("archive.photo.NEF").extension)
        assertEquals("", file("README").extension)
    }

    @Test
    fun `copy recomputes extension when filename changes`() {
        val jpeg = file("DSC_0001.JPG")

        assertEquals(".mov", jpeg.copy(fileName = "DSC_0001.MOV").extension)
    }

    private fun file(name: String) = NikonCamera.FileInfo(
        handle = 1,
        size = 100L,
        fileName = name,
        captureDate = null,
    )
}
