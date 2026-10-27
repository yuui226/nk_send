package com.ztransfer.filter

private val CUSTOM_PHOTO_FILTER_ID = Regex("np3:([0-9a-f]{64}):${PhotoNp3Parser.CONVERTER_VERSION}")
private val CUSTOM_PHOTO_FILTER_CATALOG_KEY = Regex("np3:[0-9a-f]{64}")

/** Content identity for user preferences; converter versions belong only to rendering IDs. */
fun photoFilterCatalogKey(id: String): String? = BuiltInPhotoFilters.catalogKey(id)
    ?: CUSTOM_PHOTO_FILTER_ID.matchEntire(id)?.groupValues?.get(1)?.let { "np3:$it" }

/** A remembered custom preset need not be in the currently available directory. */
fun isCustomPhotoFilterCatalogKey(key: String): Boolean = CUSTOM_PHOTO_FILTER_CATALOG_KEY.matches(key)
