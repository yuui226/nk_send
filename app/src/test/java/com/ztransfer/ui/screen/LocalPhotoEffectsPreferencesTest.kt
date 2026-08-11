package com.ztransfer.ui.screen

import com.ztransfer.frame.PhotoFramePreset
import com.ztransfer.frame.PhotoFrameWatermark
import com.ztransfer.frame.PhotoFrameWatermarkContent
import com.ztransfer.frame.PhotoFrameWatermarkFont
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class LocalPhotoEffectsPreferencesTest {
    @Test
    fun workbenchHasItsOwnDefaults() {
        val defaults = defaultLocalPhotoEffectsSettings(defaultFilterId = "forest")

        assertFalse(defaults.decorationEnabled)
        assertEquals(true, defaults.borderEnabled)
        assertEquals(PhotoFramePreset.MIST, defaults.preset)
        assertEquals(PhotoFrameWatermark(), defaults.watermark)
        assertEquals(PhotoFrameWatermarkFont.CALLIGRAPHY, defaults.watermark.font)
        assertEquals(80, defaults.watermark.sizePercent)
        assertEquals("forest", defaults.filterId)
        assertFalse(defaults.filterEnabled)
        assertEquals(80, defaults.filterIntensityPercent)
    }

    @Test
    fun invalidPersistedValuesAreNormalizedBeforeEditing() {
        val settings = LocalPhotoEffectsSettings(
            decorationEnabled = true,
            borderEnabled = false,
            preset = PhotoFramePreset.PLAQUE,
            watermark = PhotoFrameWatermark(
                content = PhotoFrameWatermarkContent.IMAGE,
                imageHash = "a".repeat(64),
                text = "line one\nline two",
                sizePercent = 999,
                opacityPercent = 0,
            ),
            filterId = "removed-filter",
            filterEnabled = true,
            filterIntensityPercent = 53,
        )

        val restored = normalizeLocalPhotoEffectsSettings(
            settings = settings,
            availableFilterIds = setOf("available-filter"),
            watermarkImageExists = { false },
        )

        assertEquals(PhotoFrameWatermarkContent.TEXT, restored.watermark.content)
        assertNull(restored.watermark.imageHash)
        assertEquals("line one line two", restored.watermark.text)
        assertEquals(300, restored.watermark.sizePercent)
        assertEquals(1, restored.watermark.opacityPercent)
        assertNull(restored.filterId)
        assertFalse(restored.filterEnabled)
        assertEquals(54, restored.filterIntensityPercent)
    }

    @Test
    fun validWatermarkAndFilterSettingsRemainSelected() {
        val hash = "b".repeat(64)
        val settings = LocalPhotoEffectsSettings(
            decorationEnabled = true,
            borderEnabled = true,
            preset = PhotoFramePreset.MIST,
            watermark = PhotoFrameWatermark(
                content = PhotoFrameWatermarkContent.IMAGE,
                imageHash = hash,
            ),
            filterId = "forest",
            filterEnabled = true,
            filterIntensityPercent = 80,
        )

        val restored = normalizeLocalPhotoEffectsSettings(
            settings = settings,
            availableFilterIds = setOf("forest"),
            watermarkImageExists = { it == hash },
        )

        assertEquals(
            settings.copy(filterIntensities = mapOf("forest" to 80)),
            restored,
        )
    }

    @Test
    fun workbenchKeepsIndependentIntensityForEachFilter() {
        val settings = defaultLocalPhotoEffectsSettings(defaultFilterId = "forest").copy(
            filterIntensityPercent = 80,
            filterIntensities = mapOf(
                "forest" to 45,
                "removed-filter" to 62,
            ),
        )

        val restored = normalizeLocalPhotoEffectsSettings(
            settings = settings,
            availableFilterIds = setOf("forest"),
            watermarkImageExists = { false },
        )

        assertEquals(46, restored.filterIntensityPercent)
        assertEquals(mapOf("forest" to 46), restored.filterIntensities)
    }
}
