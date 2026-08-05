package com.ztransfer.viewmodel

import com.ztransfer.protocol.NikonCamera
import org.junit.Assert.assertEquals
import org.junit.Test

class EffectPreviewSelectionTest {
    @Test
    fun `latest still wins and newer video is ignored`() {
        val olderJpeg = file(10, "DSC_0010.JPG", "20260805T100000")
        val latestJpeg = file(11, "DSC_0011.NEF", "20260805T110000")
        val newerVideo = file(12, "DSC_0012.MOV", "20260805T120000")

        assertEquals(latestJpeg, latestEffectPreviewFile(listOf(olderJpeg, newerVideo, latestJpeg)))
    }

    @Test
    fun `handle breaks ties when capture dates are absent`() {
        val lower = file(30, "DSC_0030.JPG", null)
        val higher = file(31, "DSC_0031.JPG", null)

        assertEquals(higher, latestEffectPreviewFile(listOf(higher, lower)))
    }

    private fun file(handle: Int, name: String, capturedAt: String?) = NikonCamera.FileInfo(
        handle = handle,
        size = 1_024L,
        fileName = name,
        captureDate = capturedAt,
    )
}
