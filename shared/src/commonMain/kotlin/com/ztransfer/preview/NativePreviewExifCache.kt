package com.ztransfer.preview

import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.viewmodel.PhotoExif
import com.ztransfer.viewmodel.exifKey

/** A present entry whose value is null is a confirmed miss, not an unattempted file. */
class NativePreviewExifCacheEntry internal constructor(val value: PhotoExif?)

/** UI-thread result cache borrowed by pages from their longer-lived workspace owner.
 * No connection/handle/URL key, eviction, reconnect reset, IO or second camera ownership.
 * Android's existing ViewModel HashMap keeps the same scope and shared exifKey rule.
 */
class NativePreviewExifCache {
    private val entries = HashMap<String, NativePreviewExifCacheEntry>()
    fun cached(file: CameraFileInfo): NativePreviewExifCacheEntry? = entries[exifKey(file)]
    fun remember(file: CameraFileInfo, exif: PhotoExif?) {
        entries[exifKey(file)] = NativePreviewExifCacheEntry(exif)
    }
}

/** Native scalar mapping for the original loadExif extension/maximum-header contract. */
object NativePreviewExifPolicy {
    fun headerBytes(file: CameraFileInfo): Int = when (file.extension) {
        ".jpg", ".jpeg" -> 128 * 1024
        ".nef", ".nrw", ".tif", ".tiff" -> 2048 * 1024
        else -> 0
    }
}
