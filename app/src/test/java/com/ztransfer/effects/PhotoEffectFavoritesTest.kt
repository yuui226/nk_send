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
    @Test fun customFavoritesRemainRememberedWhileTheirDirectoryIsUnavailable() {
        val custom = "np3:${"a".repeat(64)}"
        val other = "np3:${"b".repeat(64)}"
        val encoded = "$custom;builtin;$other;$custom;missing;np3:broken"
        val restored = decodeFavoritePhotoFilters(encoded, setOf("builtin"))
        assertEquals(listOf(FavoritePhotoFilter(custom), FavoritePhotoFilter("builtin"), FavoritePhotoFilter(other)), restored)
        assertEquals(restored, decodeFavoritePhotoFilters(encodeFavoritePhotoFilters(restored), setOf("builtin")))
    }

    @Test fun customIntensityMemorySurvivesDirectoryChangesWithoutAcceptingUnknownKeys() {
        val custom = "np3:${"c".repeat(64)}"
        val sourceId = "$custom:np3-srgb-v1"
        val restored = decodePhotoFilterIntensities(
            "$custom,37;$sourceId,42;builtin,78;missing,20;np3:broken,60;$custom,90", setOf("builtin"),
        )
        assertEquals(mapOf(custom to 38, "builtin" to 78), restored)
        assertEquals(restored, decodePhotoFilterIntensities(encodePhotoFilterIntensities(restored), setOf("builtin")))
        assertEquals(mapOf(custom to 38), decodePhotoFilterIntensities(encodePhotoFilterIntensities(restored), emptySet()))
    }

    @Test fun transferAndLocalCustomIntensityMapsRemainIndependent() {
        val custom = "np3:${"d".repeat(64)}"
        val transfer = decodePhotoFilterIntensities("$custom,20", emptySet())
        val local = decodePhotoFilterIntensities("$custom,80", emptySet())
        assertEquals(20, transfer[custom])
        assertEquals(80, local[custom])
        assertEquals("$custom,20", encodePhotoFilterIntensities(transfer))
    }

    @Test fun compactWidthFavoritesRoundTrip() {
        for (percent in listOf(60, 70, 80, 90)) {
            val favorite = FavoriteFrameWatermarkEffect.capture(PhotoFramePreset.PARAMETER_POSTER, PhotoFrameWatermark(), percent)
            assertEquals(favorite, decodeFavoriteFrameEffects(encodeFavoriteFrameEffects(listOf(favorite))).single())
        }
    }

    @Test fun backdropFavoritesRoundTrip() {
        val favorite = FavoriteFrameWatermarkEffect.capture(PhotoFramePreset.MIST, PhotoFrameWatermark(), 140, 0, 180)
        assertEquals(favorite, decodeFavoriteFrameEffects(encodeFavoriteFrameEffects(listOf(favorite))).single())
    }

    @Test
    fun frameFavoritesPersistWidthAndOldFavoritesDefaultToOriginalWidth() {
        val favorite = FavoriteFrameWatermarkEffect.capture(
            PhotoFramePreset.MIST, PhotoFrameWatermark(), 170,
        )
        assertEquals(favorite, decodeFavoriteFrameEffects(encodeFavoriteFrameEffects(listOf(favorite))).single())
        val old = encodeFavoriteFrameEffects(listOf(favorite)).substringBeforeLast(",")
        assertEquals(100, decodeFavoriteFrameEffects(old).single().frameWidthPercent)
    }

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
