package com.ztransfer.ui.screen

import com.ztransfer.frame.PhotoFrameMetadataSettings
import com.ztransfer.frame.PhotoFramePreset
import com.ztransfer.frame.PhotoFrameWatermark
import com.ztransfer.frame.PhotoFrameWatermarkPosition
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoEffectsUniformBorderTransitionTest {
    private val uniformPresets = setOf(
        PhotoFramePreset.MIST,
        PhotoFramePreset.CINEMA,
        PhotoFramePreset.MINIMAL,
        PhotoFramePreset.FROSTED,
        PhotoFramePreset.BRAND_GALLERY,
        PhotoFramePreset.CLASSIC_SIGNATURE,
    )
    private val informationOff = PhotoFrameMetadataSettings(
        showDate = false,
        showTime = false,
        showFocalLength = false,
        showExposure = false,
        showBrand = false,
        showModel = false,
    )
    private val lastInformationOn = informationOff.copy(showBrand = true)
    private val watermarkOff = PhotoFrameWatermark(enabled = false)

    private data class Frame(
        val image: Int,
        val layout: PhotoEffectsPreviewFrameLayout,
        val comparison: Boolean = false,
    )

    private fun layout(
        preset: PhotoFramePreset = PhotoFramePreset.FROSTED,
        settings: PhotoFrameMetadataSettings = informationOff,
        watermark: PhotoFrameWatermark = watermarkOff,
        borderEnabled: Boolean = true,
    ) = PhotoEffectsPreviewFrameLayout.from(borderEnabled, preset, settings, watermark)

    private fun plan(
        current: Frame?,
        next: Frame?,
        requested: PhotoEffectsPreviewFrameLayout,
    ) = planPhotoEffectsPreviewTransition(current, next, requested, Frame::layout) { a, b ->
        a.image == b.image
    }

    @Test
    fun removingAndRestoringTheLastInformationReplacesAllSixAffectedCanvases() {
        for (preset in uniformPresets) {
            val withBand = Frame(1, layout(preset, lastInformationOn))
            val uniform = Frame(2, layout(preset))
            assertFalse(preset.name, withBand.layout.uniformBorder)
            assertTrue(preset.name, uniform.layout.uniformBorder)
            assertEquals(preset.name, PhotoEffectsPreviewChange.REPLACE_CANVAS,
                plan(withBand, uniform, uniform.layout).change)
            assertEquals(preset.name, PhotoEffectsPreviewChange.REPLACE_CANVAS,
                plan(uniform, withBand, withBand.layout).change)
            assertFalse(preset.name,
                photoEffectsPreviewCanvasVisible(withBand.layout, uniform.layout, failed = false))
            assertTrue(preset.name,
                photoEffectsPreviewCanvasVisible(uniform.layout, uniform.layout, failed = false))
        }
    }

    @Test
    fun anOldInformationBandCannotBecomeTheFirstFrameAfterTheBandWasDisabled() {
        val withBand = Frame(1, layout(settings = lastInformationOn))
        val requested = layout()
        val stale = plan(null, withBand, requested)
        assertEquals(PhotoEffectsPreviewChange.KEEP, stale.change)
        assertNull(stale.frame)

        val ready = Frame(2, requested)
        val accepted = plan(stale.frame, ready, requested)
        assertEquals(PhotoEffectsPreviewChange.INITIAL, accepted.change)
        assertSame(ready, accepted.frame)
    }

    @Test
    fun reversingTheInformationSwitchRejectsThePendingUniformFrame() {
        val withBand = Frame(1, layout(settings = lastInformationOn))
        val uniform = Frame(2, layout())
        val waiting = plan(withBand, withBand, uniform.layout)
        assertEquals(PhotoEffectsPreviewChange.KEEP, waiting.change)
        assertSame(withBand, waiting.frame)

        // The user restores the information before the pending equal-border render completes.
        val reversed = plan(waiting.frame, uniform, withBand.layout)
        assertEquals(PhotoEffectsPreviewChange.KEEP, reversed.change)
        assertSame(withBand, reversed.frame)
        assertTrue(photoEffectsPreviewCanvasVisible(
            checkNotNull(reversed.frame).layout, withBand.layout, failed = false,
        ))

        // The same stale-frame protection applies in the opposite direction.
        val staleBand = plan(uniform, withBand, uniform.layout)
        assertEquals(PhotoEffectsPreviewChange.KEEP, staleBand.change)
        assertSame(uniform, staleBand.frame)
    }

    @Test
    fun movingTheWatermarkIntoOrOutOfTheBandAlsoReplacesTheCanvas() {
        val insidePhoto = PhotoFrameWatermark(position = PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT)
        val insideBand = insidePhoto.copy(position = PhotoFrameWatermarkPosition.CENTER)
        for (preset in uniformPresets) {
            val uniform = Frame(1, layout(preset, watermark = insidePhoto))
            val withBand = Frame(2, layout(preset, watermark = insideBand))
            assertTrue(preset.name, uniform.layout.uniformBorder)
            assertFalse(preset.name, withBand.layout.uniformBorder)
            assertEquals(preset.name, PhotoEffectsPreviewChange.REPLACE_CANVAS,
                plan(uniform, withBand, withBand.layout).change)
            assertEquals(preset.name, PhotoEffectsPreviewChange.REPLACE_CANVAS,
                plan(withBand, uniform, uniform.layout).change)
        }
    }

    @Test
    fun brandGalleryPhotoInformationKeepsTheCanvasUntilBrandOrModelReturnsToTheBand() {
        val preset = PhotoFramePreset.BRAND_GALLERY
        val empty = Frame(1, layout(preset))
        val photoInformation = informationOff.copy(
            showDate = true,
            showTime = true,
            showFocalLength = true,
            showExposure = true,
            showLensModel = true,
            showCoordinates = true,
            showAltitude = true,
            showCity = true,
            showRegion = true,
        )
        val insidePhoto = Frame(2, layout(preset, photoInformation))
        assertEquals(empty.layout, insidePhoto.layout)
        assertTrue(insidePhoto.layout.uniformBorder)
        assertEquals(PhotoEffectsPreviewChange.CROSSFADE,
            plan(empty, insidePhoto, insidePhoto.layout).change)

        for (withBandInformation in listOf(
            photoInformation.copy(showBrand = true),
            photoInformation.copy(showModel = true),
        )) {
            val withBand = Frame(3, layout(preset, withBandInformation))
            assertFalse(withBand.layout.uniformBorder)
            assertEquals(PhotoEffectsPreviewChange.REPLACE_CANVAS,
                plan(insidePhoto, withBand, withBand.layout).change)
            assertEquals(PhotoEffectsPreviewChange.REPLACE_CANVAS,
                plan(withBand, insidePhoto, insidePhoto.layout).change)
        }
    }

    @Test
    fun alreadyUniformBrandInsetAndSpecialTemplatesKeepTheirExistingTransitions() {
        for (preset in PhotoFramePreset.entries.filterNot { it in uniformPresets }) {
            val withInformation = Frame(1, layout(preset, lastInformationOn))
            val withoutInformation = Frame(2, layout(preset))
            assertEquals(preset.name, withInformation.layout, withoutInformation.layout)
            assertEquals(preset.name, PhotoEffectsPreviewChange.CROSSFADE,
                plan(withInformation, withoutInformation, withoutInformation.layout).change)
        }
    }

    @Test
    fun disabledBordersIgnorePresetAndInformationDrafts() {
        val original = Frame(1, layout(borderEnabled = false))
        for (preset in PhotoFramePreset.entries) {
            val changed = Frame(2, layout(
                preset,
                settings = lastInformationOn,
                watermark = PhotoFrameWatermark(position = PhotoFrameWatermarkPosition.CENTER),
                borderEnabled = false,
            ))
            assertEquals(preset.name, original.layout, changed.layout)
            assertNull(changed.layout.preset)
            assertFalse(changed.layout.uniformBorder)
            assertEquals(preset.name, PhotoEffectsPreviewChange.CROSSFADE,
                plan(original, changed, changed.layout).change)
        }
    }

    @Test
    fun effectsWithinOneLayoutStillCrossfadeAndComparisonUpdatesDoNotReplayAnimation() {
        val original = Frame(1, layout())
        val changedBackdrop = layout(settings = informationOff.copy(
            backgroundBlurPercent = 40,
            backgroundMaskPercent = 160,
        ))
        assertEquals(original.layout, changedBackdrop)
        // Filter/grain changes also produce new bitmaps without changing the frame layout.
        for (image in 2..4) {
            val changed = Frame(image, changedBackdrop)
            assertEquals(PhotoEffectsPreviewChange.CROSSFADE,
                plan(original, changed, changed.layout).change)
        }
        val comparisonReady = original.copy(comparison = true)
        assertEquals(PhotoEffectsPreviewChange.UPDATE,
            plan(original, comparisonReady, comparisonReady.layout).change)
    }
}
