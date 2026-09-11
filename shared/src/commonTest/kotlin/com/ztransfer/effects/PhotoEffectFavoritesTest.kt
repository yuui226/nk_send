package com.ztransfer.effects

import com.ztransfer.frame.PhotoFramePreset
import com.ztransfer.frame.PhotoFrameWatermark
import com.ztransfer.frame.PhotoFrameWatermarkColor
import com.ztransfer.frame.PhotoFrameWatermarkContent
import com.ztransfer.frame.PhotoFrameWatermarkEffect
import com.ztransfer.frame.PhotoFrameWatermarkFont
import com.ztransfer.frame.PhotoFrameWatermarkPosition
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class PhotoEffectFavoritesTest {
    @Test
    fun filterCodecPreservesOrderMigratesLegacyValuesAndDropsInvalidEntries() {
        val decoded = decodeFavoritePhotoFilters(
            encoded = "cinema_blue,71;missing,80;cinema_blue,92;soft_portrait,101;broken",
            validCatalogKeys = setOf("cinema_blue", "soft_portrait"),
        )

        assertEquals(
            listOf(
                FavoritePhotoFilter("cinema_blue"),
                FavoritePhotoFilter("soft_portrait"),
            ),
            decoded,
        )
        assertEquals("cinema_blue;soft_portrait", encodeFavoritePhotoFilters(decoded))
    }

    @Test
    fun filterIntensityMemoryUsesStableKeysAndNormalizesValues() {
        val restored = decodePhotoFilterIntensities(
            encoded = "soft_portrait,79;missing,60;soft_portrait,22;cinema_blue,101;broken",
            validCatalogKeys = setOf("soft_portrait", "cinema_blue"),
        )

        assertEquals(
            mapOf("soft_portrait" to 80, "cinema_blue" to 100),
            restored,
        )
        assertEquals(
            "cinema_blue,100;soft_portrait,80",
            encodePhotoFilterIntensities(restored),
        )
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
