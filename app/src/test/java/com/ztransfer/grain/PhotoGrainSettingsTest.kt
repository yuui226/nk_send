package com.ztransfer.grain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoGrainSettingsTest {
    @Test fun strengthCommitThenOffWithoutRecompositionKeepsTheNewValue() {
        val before = PhotoGrainSettings(20, true, PhotoGrainStyle.COARSE)
        val oldMemories = normalizedPhotoGrainIntensities(mapOf(PhotoGrainStyle.COARSE to 20))
        var draft = before
        // These callbacks share a composition but resolve the current draft at invocation time.
        val strengthRelease = { draft = draft.changeIntensity(before.style, 73) }
        val switchOff = { draft = draft.selectStyle(null, oldMemories) }
        strengthRelease()
        switchOff()
        assertEquals(PhotoGrainSettings(73, false, PhotoGrainStyle.COARSE), draft)
        assertEquals(PhotoGrainSettings(73, true, PhotoGrainStyle.COARSE),
            draft.selectStyle(PhotoGrainStyle.COARSE, oldMemories))
    }

    @Test fun lateStrengthReleaseCannotReenableOrOverwriteAnotherStyle() {
        val coarse = PhotoGrainSettings(20, true, PhotoGrainStyle.COARSE)
        val off = coarse.selectStyle(null, emptyMap())
        assertEquals(off, off.changeIntensity(PhotoGrainStyle.COARSE, 73))
        val fine = coarse.selectStyle(PhotoGrainStyle.FINE, mapOf(PhotoGrainStyle.FINE to 37))
        assertEquals(PhotoGrainSettings(37, true), fine)
        assertEquals(fine, fine.changeIntensity(PhotoGrainStyle.COARSE, 73))
    }

    @Test fun switchingStylesRestoresEachMemoryIncludingZeroAndUsesItsOwnDefault() {
        val memories = mapOf(PhotoGrainStyle.FINE to 0, PhotoGrainStyle.COARSE to 73)
        var draft = PhotoGrainSettings(20, false, PhotoGrainStyle.MEDIUM)
        draft = draft.selectStyle(PhotoGrainStyle.COARSE, memories)
        assertEquals(PhotoGrainSettings(73, true, PhotoGrainStyle.COARSE), draft)
        draft = draft.selectStyle(PhotoGrainStyle.FINE, memories)
        assertEquals(PhotoGrainSettings(0, true, PhotoGrainStyle.FINE), draft)
        draft = draft.selectStyle(PhotoGrainStyle.MEDIUM, memories)
        assertEquals(PhotoGrainSettings(40, true, PhotoGrainStyle.MEDIUM), draft)
    }

    @Test fun stylesHaveStableIdsAndRetainTheirRecipeWhenNormalized() {
        assertEquals(listOf("fine", "medium", "coarse"), PhotoGrainStyle.entries.map { it.id })
        assertEquals(listOf(0, 1, 2), PhotoGrainStyle.entries.map { it.nativeId })
        assertEquals(listOf(50, 40, 30), PhotoGrainStyle.entries.map { it.defaultIntensityPercent })
        for (style in PhotoGrainStyle.entries) {
            assertEquals(style, PhotoGrainStyle.fromId(style.id))
            assertEquals(PhotoGrainSettings(100, false, style),
                PhotoGrainSettings(150, false, style).normalized())
        }
        assertEquals(PhotoGrainStyle.FINE, PhotoGrainStyle.fromId(null))
        assertEquals(PhotoGrainStyle.FINE, PhotoGrainStyle.fromId("unknown"))
        assertEquals(mapOf(PhotoGrainStyle.FINE to 0, PhotoGrainStyle.MEDIUM to 40,
            PhotoGrainStyle.COARSE to 100), normalizedPhotoGrainIntensities(
            mapOf(PhotoGrainStyle.FINE to -5, PhotoGrainStyle.COARSE to 150)))
    }

    @Test fun styleDefaultsFillOnlyMissingMemories() {
        assertEquals(mapOf(PhotoGrainStyle.FINE to 50, PhotoGrainStyle.MEDIUM to 40,
            PhotoGrainStyle.COARSE to 30), normalizedPhotoGrainIntensities())
        for (stored in listOf(0, 50)) {
            val memories = PhotoGrainStyle.entries.associateWith { stored }
            assertEquals(memories, normalizedPhotoGrainIntensities(memories))
        }
        assertEquals(mapOf(PhotoGrainStyle.FINE to 0, PhotoGrainStyle.MEDIUM to 50,
            PhotoGrainStyle.COARSE to 30), normalizedPhotoGrainIntensities(
            mapOf(PhotoGrainStyle.FINE to 0, PhotoGrainStyle.MEDIUM to 50)))
    }

    @Test fun defaultsOffWithRememberedMidpointAndNormalizesWithoutChangingSwitch() {
        assertEquals(PhotoGrainSettings(50, enabled = false), PhotoGrainSettings.OFF)
        assertFalse(PhotoGrainSettings.OFF.isEnabled)
        assertFalse(PhotoGrainSettings(-10, enabled = true).isEnabled)
        assertEquals(PhotoGrainSettings(0, enabled = true),
            PhotoGrainSettings(-10, enabled = true).normalized())
        assertEquals(PhotoGrainSettings(100, enabled = true),
            PhotoGrainSettings(150, enabled = true).normalized())
        assertEquals(PhotoGrainSettings(100, enabled = false),
            PhotoGrainSettings(150, enabled = false).normalized())
        assertTrue(PhotoGrainSettings(1, enabled = true).isEnabled)
        assertFalse(PhotoGrainSettings(0, enabled = true).isEnabled)
    }

    @Test fun disablingAndReenablingRetainsExactIntensity() {
        val selected = PhotoGrainSettings(73, enabled = true)
        val disabled = selected.copy(enabled = false).normalized()
        assertEquals(73, disabled.intensityPercent)
        assertFalse(disabled.isEnabled)
        assertEquals(selected, disabled.copy(enabled = true))
    }

    @Test fun sourceIdentityIsStableAcrossProviderPathsAndCasing() {
        val expected = photoGrainSeed("DSC_0123.JPG")
        assertEquals(expected, photoGrainSeed("/storage/card/dsc_0123.jpg"))
        assertEquals(expected, photoGrainSeed("C:\\Photos\\DSC_0123.JPG"))
        assertTrue(expected != photoGrainSeed("DSC_0124.JPG"))
        assertEquals(0x811c9dc5.toInt(), photoGrainSeed(""))
    }

    @Test fun scratchMemoryRemainsBoundedForLargePhotos() {
        assertEquals(600 * 400, PhotoGrainRenderer.scratchPixelCount(600, 400))
        assertTrue(PhotoGrainRenderer.scratchPixelCount(12000, 8000) <= 512 * 1024)
        assertEquals(12000, PhotoGrainRenderer.scratchPixelCount(12000, 1))
    }
}
