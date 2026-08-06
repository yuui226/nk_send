package com.ztransfer.frame

import com.ztransfer.filter.NcpPhotoFilterParameters
import com.ztransfer.filter.PhotoFilterPreset
import com.ztransfer.filter.PhotoFilterSelection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoFilterOutputTest {
    @Test
    fun filterOnlyCopyHasStableRecognizableName() {
        val selection = PhotoFilterSelection(testFilter("0123456789abcdef"), 72)
        val name = photoFrameOutputName(
            sourceName = "DSC_0001.JPG",
            preset = PhotoFramePreset.MIST,
            watermark = PhotoFrameWatermark(enabled = false),
            borderEnabled = false,
            filter = selection,
        )

        assertEquals("DSC_0001_filter_f01234567i72.jpg", name)
        assertTrue(isPhotoFrameOutputName(name))
        assertTrue(
            isPhotoFrameOutputFor(
                name = name,
                sourceName = "DSC_0001.JPG",
                preset = PhotoFramePreset.MIST,
                watermark = PhotoFrameWatermark(enabled = false),
                borderEnabled = false,
                filter = selection,
            )
        )
    }

    @Test
    fun changingFilterOrIntensityCreatesADifferentDerivedIdentity() {
        val first = PhotoFilterSelection(testFilter("aaaaaaaa11111111"), 40)
        val otherFilter = PhotoFilterSelection(testFilter("bbbbbbbb22222222"), 40)
        val otherIntensity = first.copy(intensityPercent = 42)

        val firstName = outputName(first)
        assertTrue(firstName != outputName(otherFilter))
        assertTrue(firstName != outputName(otherIntensity))
        assertTrue(!isPhotoFrameOutputFor(
            name = firstName,
            sourceName = "PHOTO.PNG",
            preset = PhotoFramePreset.MIST,
            watermark = PhotoFrameWatermark(enabled = false),
            borderEnabled = false,
            filter = otherIntensity,
        ))
    }

    private fun outputName(filter: PhotoFilterSelection): String = photoFrameOutputName(
        sourceName = "PHOTO.PNG",
        preset = PhotoFramePreset.MIST,
        watermark = PhotoFrameWatermark(enabled = false),
        borderEnabled = false,
        filter = filter,
    )

    private fun testFilter(id: String) = PhotoFilterPreset(
        id = id,
        name = "Test",
        parameters = NcpPhotoFilterParameters(
            saturationStep = 0,
            hueStep = 0,
            toneCurve = IntArray(257) { index -> (index * 0x7fff) / 256 },
        ),
    )
}
