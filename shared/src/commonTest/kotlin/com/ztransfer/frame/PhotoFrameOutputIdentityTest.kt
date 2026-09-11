package com.ztransfer.frame

import com.ztransfer.filter.NcpPhotoFilterParameters
import com.ztransfer.filter.PhotoFilterPreset
import com.ztransfer.filter.PhotoFilterSelection
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull

class PhotoFrameOutputIdentityTest {
    private val filter = PhotoFilterSelection(
        preset = PhotoFilterPreset(
            id = "sample",
            name = "Sample",
            parameters = NcpPhotoFilterParameters(0, 0, IntArray(257) { it * 0x7fff / 256 }),
        ),
        intensityPercent = 79,
    )

    @Test
    fun materialKeepsTheExistingVersionAndLegacyTokens() {
        assertEquals("v=2\u0000sample", photoFilterRenderFingerprintMaterial(filter))
        assertEquals(
            "v=2\u0000on\u0000TEXT\u0000129P\u0000CENTER\u0000opacity=STANDARD\u0000" +
                "ZTransfer\u0000CALLIGRAPHY\u0000ADAPTIVE\u0000effect=AUTO",
            photoFrameWatermarkFingerprintMaterial(
                PhotoFrameWatermark(),
                PhotoFramePreset.MIST,
            ),
        )
    }

    @Test
    fun outputIdentityMatchesBorderWatermarkAndFilterModes() {
        val framed = photoFrameOutputIdentity(PhotoFramePreset.PLAQUE, filter = filter)
        assertEquals("frame_plaque", framed.styleSuffix)
        assertEquals(80, framed.filterIntensityPercent)
        assertEquals("v=2\u0000sample", framed.filterFingerprintMaterial)

        val filterOnly = photoFrameOutputIdentity(
            preset = PhotoFramePreset.MIST,
            watermark = PhotoFrameWatermark(enabled = false),
            borderEnabled = false,
            filter = filter,
        )
        assertEquals("filter", filterOnly.styleSuffix)
        assertNull(filterOnly.watermarkFingerprintMaterial)

        val watermarkOnly = photoFrameOutputIdentity(
            preset = PhotoFramePreset.MIST,
            borderEnabled = false,
        )
        assertEquals("watermark", watermarkOnly.styleSuffix)
        assertNotEquals(null, watermarkOnly.watermarkFingerprintMaterial)
    }

    @Test
    fun hiddenTextControlsDoNotChangeImageWatermarkMaterial() {
        val first = PhotoFrameWatermark(
            content = PhotoFrameWatermarkContent.IMAGE,
            imageHash = "a".repeat(64),
            text = "first",
            font = PhotoFrameWatermarkFont.BOLD,
        )
        val samePixels = first.copy(text = "second", font = PhotoFrameWatermarkFont.SIMPLE)
        assertEquals(
            photoFrameWatermarkFingerprintMaterial(first, PhotoFramePreset.MIST),
            photoFrameWatermarkFingerprintMaterial(samePixels, PhotoFramePreset.MIST),
        )
    }
}
