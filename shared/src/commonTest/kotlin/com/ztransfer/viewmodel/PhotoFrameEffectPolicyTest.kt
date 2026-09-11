package com.ztransfer.viewmodel

import com.ztransfer.frame.PhotoFrameWatermark
import com.ztransfer.frame.PhotoFrameWatermarkColor
import com.ztransfer.frame.PhotoFrameWatermarkContent
import com.ztransfer.frame.PhotoFrameWatermarkEffect
import com.ztransfer.frame.PhotoFrameWatermarkFont
import com.ztransfer.frame.PhotoFrameWatermarkPosition
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PhotoFrameEffectPolicyTest {
    @Test
    fun restoresLegacyAndCurrentWatermarkPercentages() {
        assertEquals(80, restoredPhotoFrameWatermarkSizePercent(null, PhotoFrameWatermarkContent.TEXT))
        assertEquals(9, restoredPhotoFrameWatermarkSizePercent("SMALL", PhotoFrameWatermarkContent.TEXT))
        assertEquals(26, restoredPhotoFrameWatermarkSizePercent("MEDIUM", PhotoFrameWatermarkContent.TEXT))
        assertEquals(1, restoredPhotoFrameWatermarkSizePercent("SMALL", PhotoFrameWatermarkContent.IMAGE))
        assertEquals(20, restoredPhotoFrameWatermarkSizePercent("MEDIUM", PhotoFrameWatermarkContent.IMAGE))
        assertEquals(51, restoredPhotoFrameWatermarkSizePercent("LARGE", PhotoFrameWatermarkContent.IMAGE))
        assertEquals(
            151,
            restoredPhotoFrameWatermarkSizePercent(
                200,
                PhotoFrameWatermarkContent.TEXT,
                usesLegacyScale = true,
            ),
        )
        assertEquals(300, restoredPhotoFrameWatermarkSizePercent(300, PhotoFrameWatermarkContent.TEXT))
        assertEquals(40, restoredPhotoFrameWatermarkOpacityPercent("SUBTLE"))
        assertEquals(72, restoredPhotoFrameWatermarkOpacityPercent("STANDARD"))
        assertEquals(100, restoredPhotoFrameWatermarkOpacityPercent("STRONG"))
        assertEquals(100, restoredPhotoFrameWatermarkOpacityPercent(140))
    }

    @Test
    fun freeAndProWatermarkResolutionPreservesExistingRules() {
        val preference = PhotoFrameWatermark(
            enabled = false,
            text = "My camera",
            font = PhotoFrameWatermarkFont.BOLD,
            sizePercent = 999,
            position = PhotoFrameWatermarkPosition.RIGHT,
            color = PhotoFrameWatermarkColor.GOLD,
            opacityPercent = 0,
            effect = PhotoFrameWatermarkEffect.OUTLINE,
        )

        assertEquals(freeEditionPhotoFrameWatermark(), effectivePhotoFrameWatermark(false, preference))
        val pro = effectivePhotoFrameWatermark(true, preference)
        assertFalse(pro.enabled)
        assertEquals(300, pro.sizePercent)
        assertEquals(1, pro.opacityPercent)
        assertEquals(PhotoFrameWatermarkEffect.OUTLINE, pro.effect)
    }

    @Test
    fun imageAndBorderConstraintsKeepPreferenceSeparateFromRenderedPosition() {
        val validImage = PhotoFrameWatermark(
            content = PhotoFrameWatermarkContent.IMAGE,
            imageHash = "a".repeat(64),
            position = PhotoFrameWatermarkPosition.LEFT,
            opacityPercent = 140,
        )
        val normalized = normalizedPhotoFrameWatermarkPreference(validImage, borderEnabled = false)
        assertEquals(PhotoFrameWatermarkContent.IMAGE, normalized.content)
        assertEquals(PhotoFrameWatermarkPosition.LEFT, normalized.position)
        assertEquals(100, normalized.opacityPercent)
        assertEquals(
            PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER,
            effectivePhotoFrameWatermark(true, normalized, borderEnabled = false).position,
        )

        val invalidImage = effectivePhotoFrameWatermark(
            true,
            validImage.copy(imageHash = "not-a-hash"),
        )
        assertEquals(PhotoFrameWatermarkContent.TEXT, invalidImage.content)
        assertEquals(PhotoFrameWatermarkPosition.LEFT, invalidImage.position)
    }

    @Test
    fun generationGateAcceptsOnlyEnabledBitmapFormats() {
        listOf(".jpg", ".JPEG", ".png", ".PNG").forEach {
            assertTrue(shouldGeneratePhotoFrame(enabled = true, extension = it))
        }
        listOf(".mov", ".mp4", ".nef").forEach {
            assertFalse(shouldGeneratePhotoFrame(enabled = true, extension = it))
        }
        assertFalse(shouldGeneratePhotoFrame(enabled = false, extension = ".jpg"))
    }
}
