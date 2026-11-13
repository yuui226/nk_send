package com.ztransfer.filter

internal enum class PhotoNp3RecipeKind(val converterVersion: String) {
    FLEXIBLE(PhotoNp3Parser.CONVERTER_VERSION),
    CLASSIC(PhotoNp3Parser.CLASSIC_CONVERTER_VERSION),
}

private val CUSTOM_PHOTO_FILTER_ID = Regex(
    "np3:([0-9a-f]{64}):(" +
        PhotoNp3RecipeKind.entries.joinToString("|") { Regex.escape(it.converterVersion) } + ")",
)
private val CUSTOM_PHOTO_FILTER_CATALOG_KEY = Regex("np3:[0-9a-f]{64}")

internal fun photoNp3SourceSha256(id: String): String? =
    CUSTOM_PHOTO_FILTER_ID.matchEntire(id)?.groupValues?.get(1)

internal fun photoNp3RecipeKind(id: String): PhotoNp3RecipeKind? {
    val version = CUSTOM_PHOTO_FILTER_ID.matchEntire(id)?.groupValues?.get(2) ?: return null
    return PhotoNp3RecipeKind.entries.first { it.converterVersion == version }
}

/** Content identity for user preferences; converter versions belong only to rendering IDs. */
fun photoFilterCatalogKey(id: String): String? = BuiltInPhotoFilters.catalogKey(id)
    ?: photoNp3SourceSha256(id)?.let { "np3:$it" }

/** A remembered custom preset need not be in the currently available directory. */
fun isCustomPhotoFilterCatalogKey(key: String): Boolean = CUSTOM_PHOTO_FILTER_CATALOG_KEY.matches(key)
