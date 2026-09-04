package com.ztransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

class FileInfoExtensionTest {
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
