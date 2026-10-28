package com.ztransfer.effects

import org.junit.Assert.assertEquals
import org.junit.Test

class SharedPhotoFilterFavoritesTest {
    private val builtIns = setOf("cinema_blue", "soft_portrait", "warm_film")

    @Test fun preservesSharedOrderAndAppendsOnlyDistinctLocalFavorites() {
        val merged = mergePhotoFilterFavorites(
            shared = "soft_portrait;cinema_blue;soft_portrait",
            legacyLocal = "cinema_blue;warm_film;soft_portrait;warm_film",
            validCatalogKeys = builtIns,
        )

        assertEquals(favorites("soft_portrait", "cinema_blue", "warm_film"), merged)
    }

    @Test fun emptySidesDoNotInventOrDiscardFavorites() {
        assertEquals(emptyList<FavoritePhotoFilter>(), mergePhotoFilterFavorites(null, null, builtIns))
        assertEquals(emptyList<FavoritePhotoFilter>(), mergePhotoFilterFavorites("", " ", builtIns))
        assertEquals(favorites("cinema_blue", "soft_portrait"), mergePhotoFilterFavorites(
            null, "cinema_blue;soft_portrait", builtIns,
        ))
        assertEquals(favorites("soft_portrait", "cinema_blue"), mergePhotoFilterFavorites(
            "soft_portrait;cinema_blue", "", builtIns,
        ))
    }

    @Test fun legacyIntensitySuffixesAreIgnoredAndInvalidEntriesAreDiscarded() {
        val merged = mergePhotoFilterFavorites(
            shared = "cinema_blue,42;missing;np3:broken;soft_portrait,80;cinema_blue,95",
            legacyLocal = "warm_film,60;missing,20;bad key;soft_portrait,12;np3:broken",
            validCatalogKeys = builtIns,
        )

        assertEquals(favorites("cinema_blue", "soft_portrait", "warm_film"), merged)
        assertEquals("cinema_blue;soft_portrait;warm_film", encodeFavoritePhotoFilters(merged))
    }

    @Test fun validCustomKeysSurviveWithoutCurrentlyLoadedPresetAndDeduplicateAcrossRoles() {
        val customA = "np3:${"a".repeat(64)}"
        val customB = "np3:${"b".repeat(64)}"
        val merged = mergePhotoFilterFavorites(
            shared = "$customA,24;cinema_blue;$customA",
            legacyLocal = "$customB;$customA,90;$customB;np3:short",
            validCatalogKeys = builtIns,
        )

        assertEquals(favorites(customA, "cinema_blue", customB), merged)
        assertEquals(merged, decodeFavoritePhotoFilters(encodeFavoritePhotoFilters(merged), builtIns))
    }

    private fun favorites(vararg keys: String) = keys.map(::FavoritePhotoFilter)
}
