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
    fun catalogKey(index: Int): String? = BuiltInPhotoFilters.all.getOrNull(index)?.let {
        BuiltInPhotoFilters.catalogKey(it.id)
    }
}
