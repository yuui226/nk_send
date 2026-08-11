package com.ztransfer.effects

import com.ztransfer.frame.PhotoFramePreset
import com.ztransfer.frame.PhotoFrameWatermark
import com.ztransfer.frame.PhotoFrameWatermarkColor
import com.ztransfer.frame.PhotoFrameWatermarkContent
import com.ztransfer.frame.PhotoFrameWatermarkEffect
import com.ztransfer.frame.PhotoFrameWatermarkFont
import com.ztransfer.frame.PhotoFrameWatermarkPosition
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PhotoEffectFavoritesTest {
    @Test
    fun filterCodecPreservesOrderNormalizesIntensityAndDropsInvalidEntries() {
        val decoded = decodeFavoritePhotoFilters(
            encoded = "cinema_blue,71;missing,80;cinema_blue,92;soft_portrait,101;broken",
            validCatalogKeys = setOf("cinema_blue", "soft_portrait"),
        )

        assertEquals(
            listOf(
                FavoritePhotoFilter("cinema_blue", 72),
                FavoritePhotoFilter("soft_portrait", 100),
            ),
            decoded,
        )
        assertEquals("cinema_blue,72;soft_portrait,100", encodeFavoritePhotoFilters(decoded))
    }

    @Test
    fun frameCodecPreservesOrderAndDropsDuplicateOrMalformedPresets() {
        val cinema = FavoriteFrameWatermarkEffect.capture(
            PhotoFramePreset.CINEMA,
            PhotoFrameWatermark(
                enabled = true,
                content = PhotoFrameWatermarkContent.TEXT,
                font = PhotoFrameWatermarkFont.BOLD,
                sizePercent = 48,
                position = PhotoFrameWatermarkPosition.RIGHT,
                color = PhotoFrameWatermarkColor.GOLD,
                opacityPercent = 81,
                effect = PhotoFrameWatermarkEffect.SHADOW,
            ),
        )
        val encoded = encodeFavoriteFrameEffects(listOf(cinema))

        assertEquals(listOf(cinema), decodeFavoriteFrameEffects("$encoded;$encoded;broken"))
    }

    @Test
    fun applyingFrameFavoriteKeepsCurrentTextAndImageIdentity() {
        val favorite = FavoriteFrameWatermarkEffect.capture(
            PhotoFramePreset.MINIMAL,
            PhotoFrameWatermark(
                enabled = true,
                content = PhotoFrameWatermarkContent.IMAGE,
                text = "historical text",
                imageHash = "a".repeat(64),
                sizePercent = 42,
                position = PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT,
                color = PhotoFrameWatermarkColor.ROSE_GOLD,
                opacityPercent = 66,
                effect = PhotoFrameWatermarkEffect.OUTLINE,
            ),
        )
        val current = PhotoFrameWatermark(
            text = "current text",
            imageHash = "b".repeat(64),
        )

        val applied = requireNotNull(favorite.applyTo(current))

        assertEquals("current text", applied.text)
        assertEquals("b".repeat(64), applied.imageHash)
        assertEquals(PhotoFrameWatermarkContent.IMAGE, applied.content)
        assertEquals(42, applied.sizePercent)
        assertEquals(66, applied.opacityPercent)
    }

    @Test
    fun applyingFavoriteUsesContentSourceWhenEditorShowsDisabledFallback() {
        val favorite = FavoriteFrameWatermarkEffect.capture(
            PhotoFramePreset.MINIMAL,
            PhotoFrameWatermark(
                enabled = true,
                content = PhotoFrameWatermarkContent.IMAGE,
                sizePercent = 42,
            ),
        )
        val editorFallback = PhotoFrameWatermark(enabled = false)
        val currentDraft = PhotoFrameWatermark(
            text = "current text",
            imageHash = "c".repeat(64),
        )

        val applied = requireNotNull(
            favorite.applyTo(
                current = editorFallback,
                contentSource = currentDraft,
            ),
        )

        assertEquals("current text", applied.text)
        assertEquals("c".repeat(64), applied.imageHash)
        assertEquals(PhotoFrameWatermarkContent.IMAGE, applied.content)
        assertEquals(42, applied.sizePercent)
    }

    @Test
    fun imageFavoriteCannotApplyWithoutCurrentImage() {
        val favorite = FavoriteFrameWatermarkEffect.capture(
            PhotoFramePreset.MIST,
            PhotoFrameWatermark(content = PhotoFrameWatermarkContent.IMAGE),
        )

        assertNull(favorite.applyTo(PhotoFrameWatermark(imageHash = null)))
    }

    @Test
    fun favoriteOrderingUsesFavoriteSequenceThenOriginalOrderWithoutDuplicates() {
        val ordered = orderWithFavorites(
            items = listOf("a", "b", "c", "d"),
            favoriteKeys = listOf("c", "a", "c", "missing"),
            keyOf = { it },
        )

        assertEquals(listOf("c", "a", "b", "d"), ordered)
    }
}
