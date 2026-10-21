package com.ztransfer.ui.screen

import com.ztransfer.filter.NcpPhotoFilterParameters
import com.ztransfer.filter.PhotoFilterPreset
import com.ztransfer.filter.PhotoFilterSelection
import com.ztransfer.grain.PhotoGrainSettings
import com.ztransfer.grain.PhotoGrainStyle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class PhotoEffectsGrainPreviewKeyTest {
    @Test
    fun eachStyleHasItsOwnPreviewWhileDisabledStylesShareTheOriginal() {
        val settings = PhotoGrainSettings(37, enabled = true)
        val keys = PhotoGrainStyle.entries.map { style ->
            PhotoEffectsPreviewCacheKey.from(null, settings.copy(style = style), 123)
        }
        assertEquals(PhotoGrainStyle.entries.size, keys.distinct().size)
        PhotoGrainStyle.entries.forEach { style ->
            assertEquals(PhotoEffectsPreviewCacheKey.from(null), PhotoEffectsPreviewCacheKey.from(
                null, settings.copy(style = style, enabled = false), 123,
            ))
            assertEquals(PhotoEffectsPreviewCacheKey.from(null), PhotoEffectsPreviewCacheKey.from(
                null, settings.copy(style = style, intensityPercent = 0), 123,
            ))
        }
    }

    @Test
    fun grainOnlyFramesDoNotReuseOriginalOrOtherIntensityOrSeed() {
        val original = PhotoEffectsPreviewCacheKey.from(null)
        val grain = PhotoEffectsPreviewCacheKey.from(null, PhotoGrainSettings(37, enabled = true), 123)
        assertNotEquals(original, grain)
        assertNotEquals(grain, PhotoEffectsPreviewCacheKey.from(null, PhotoGrainSettings(38, enabled = true), 123))
        assertNotEquals(grain, PhotoEffectsPreviewCacheKey.from(null, PhotoGrainSettings(37, enabled = true), 124))
        assertEquals(grain, PhotoEffectsPreviewCacheKey.from(null, PhotoGrainSettings(37, enabled = true), 123))
    }

    @Test
    fun disabledAndNormalizedGrainHaveOneStableCacheIdentity() {
        assertEquals(PhotoEffectsPreviewCacheKey.from(null),
            PhotoEffectsPreviewCacheKey.from(null, PhotoGrainSettings(-1, enabled = true), 567))
        for (intensity in listOf(0, 37, 100)) {
            assertEquals(PhotoEffectsPreviewCacheKey.from(null),
                PhotoEffectsPreviewCacheKey.from(null, PhotoGrainSettings(intensity, enabled = false), 567))
        }
        assertEquals(PhotoEffectsPreviewCacheKey.from(null, PhotoGrainSettings(100, enabled = true), 567),
            PhotoEffectsPreviewCacheKey.from(null, PhotoGrainSettings(101, enabled = true), 567))
    }

    @Test
    fun grainAndFilterParametersBothParticipateInIdentity() {
        val preset = PhotoFilterPreset("test", "Test", NcpPhotoFilterParameters(
            saturationStep = 0, hueStep = 0, toneCurve = IntArray(257) { it * 0x7fff / 256 },
        ))
        val selection = PhotoFilterSelection(preset, 80)
        val key = PhotoEffectsPreviewCacheKey.from(selection, PhotoGrainSettings(37, enabled = true), 123)
        assertNotEquals(key, PhotoEffectsPreviewCacheKey.from(selection))
        assertNotEquals(key, PhotoEffectsPreviewCacheKey.from(null, PhotoGrainSettings(37, enabled = true), 123))
        assertNotEquals(key, PhotoEffectsPreviewCacheKey.from(PhotoFilterSelection(preset, 60), PhotoGrainSettings(37, enabled = true), 123))
        assertEquals(80, key.intensityPercent)
        assertEquals(37, key.grainIntensityPercent)
    }
}
