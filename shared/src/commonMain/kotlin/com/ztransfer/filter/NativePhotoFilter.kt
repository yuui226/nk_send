package com.ztransfer.filter

/** Bounded Native entry; same compiled kernel as Android, with no approximate Core Image LUT. */
class NativePhotoFilter(selection: PhotoFilterSelection, preserveAlpha: Boolean) {
    private val compiled = compilePhotoFilter(selection, preserveAlpha)

    /** A caller checks its cancellation between chunks; invalid ranges never escape as exceptions. */
    fun render(pixels: IntArray, count: Int): Boolean {
        if (count !in 0..minOf(pixels.size, MAX_CHUNK_PIXELS)) return false
        renderPhotoFilterArgbRange(pixels, 0, count, compiled)
        return true
    }

    companion object { const val MAX_CHUNK_PIXELS = 4096 }
}

object NativePhotoFilterCatalog {
    fun count(): Int = BuiltInPhotoFilters.all.size
    fun selection(index: Int, intensityPercent: Int): PhotoFilterSelection? =
        BuiltInPhotoFilters.all.getOrNull(index)?.let { PhotoFilterSelection(it, intensityPercent) }

    /** Stable scalar accessors for Swift/iOS; avoids leaking Kotlin collection wrappers into UI. */
    fun id(index: Int): String? = BuiltInPhotoFilters.all.getOrNull(index)?.id
    fun name(index: Int): String? = BuiltInPhotoFilters.all.getOrNull(index)?.name
    fun categoryTitle(index: Int): String? = BuiltInPhotoFilters.all.getOrNull(index)?.category()?.title
    fun categoryId(index: Int): String? = BuiltInPhotoFilters.all.getOrNull(index)?.category()?.name
    fun catalogKey(index: Int): String? = BuiltInPhotoFilters.all.getOrNull(index)?.let {
        BuiltInPhotoFilters.catalogKey(it.id)
    }

    /** Comma-separated indexes keep the Native bridge scalar and stable on Apple platforms. */
    fun orderedIndexCsv(categoryId: String, favoriteCatalogKeysCsv: String): String {
        val category = PhotoFilterCategory.values().firstOrNull { it.name == categoryId }
            ?: PhotoFilterCategory.ALL
        val favorites = favoriteCatalogKeysCsv.split(FAVORITE_KEY_SEPARATOR).filter(String::isNotBlank)
        return BuiltInPhotoFilters.all.orderForCategory(category, favorites) {
            BuiltInPhotoFilters.catalogKey(it.id) ?: it.id
        }.map { BuiltInPhotoFilters.all.indexOf(it) }.joinToString(",")
    }

    private const val FAVORITE_KEY_SEPARATOR = "\u001F"
}
