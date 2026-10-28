package com.ztransfer.effects

import android.content.Context

private const val SHARED_FAVORITES_MIGRATED = "photo_filter_favorites_shared_v1"

/** Preserve camera-list ordering, then append phone-only favorites without duplicates. */
internal fun mergePhotoFilterFavorites(
    shared: String?,
    legacyLocal: String?,
    validCatalogKeys: Set<String>,
): List<FavoritePhotoFilter> =
    (decodeFavoritePhotoFilters(shared, validCatalogKeys) +
        decodeFavoritePhotoFilters(legacyLocal, validCatalogKeys)).distinctBy { it.catalogKey }

/** After this one-time merge, both editors use the ViewModel's single shared favorites list. */
internal fun restoreSharedPhotoFilterFavorites(
    context: Context,
    validCatalogKeys: Set<String>,
): List<FavoritePhotoFilter> {
    val app = context.applicationContext
    val preferences = app.getSharedPreferences("ztransfer", Context.MODE_PRIVATE)
    return synchronized(preferences) {
        val values = preferences.all
        val migrated = values[SHARED_FAVORITES_MIGRATED] == true
        val encoded = values[FAVORITE_PHOTO_FILTERS_PREFERENCE_KEY] as? String
        val legacyLocal = if (migrated) null else app
            .getSharedPreferences("local_photo_effects", Context.MODE_PRIVATE)
            .all[FAVORITE_PHOTO_FILTERS_PREFERENCE_KEY] as? String
        val favorites = mergePhotoFilterFavorites(encoded, legacyLocal, validCatalogKeys)
        val normalized = encodeFavoritePhotoFilters(favorites)
        if (!migrated || normalized != encoded) {
            // Mark migration and save its result together. Keep the old local key untouched:
            // interrupted upgrades can retry, but later removals/dir resets never re-import it.
            preferences.edit().putString(FAVORITE_PHOTO_FILTERS_PREFERENCE_KEY, normalized)
                .putBoolean(SHARED_FAVORITES_MIGRATED, true).apply()
        }
        favorites
    }
}
