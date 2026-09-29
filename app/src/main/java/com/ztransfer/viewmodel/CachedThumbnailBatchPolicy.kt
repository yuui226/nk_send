package com.ztransfer.viewmodel

/** Per-scan policy; only complete batches of pre-existing thumbnails accelerate the next batch. */
internal class CachedThumbnailBatchPolicy {
    @Volatile var size: Int = 12
        private set

    fun complete(count: Int, allCached: Boolean) {
        size = if (allCached && count >= size) (size * 2).coerceAtMost(48) else 12
    }
}
