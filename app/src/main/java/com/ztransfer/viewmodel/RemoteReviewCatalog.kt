package com.ztransfer.viewmodel

import com.ztransfer.protocol.NikonCamera
import com.ztransfer.protocol.selectNewestFileHeadIndex
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

private val REVIEW_PHOTO_EXTENSIONS = setOf(".jpg", ".jpeg", ".nef", ".nrw", ".tif", ".tiff", ".heif", ".hif", ".heic")

/** A capture is one review page, even when JPEG/RAW or backup cards produce several objects. */
internal fun reviewCaptureKey(file: NikonCamera.FileInfo): String =
    if (file.captureDate.isNullOrBlank()) "handle:${file.handle}"
    else "${file.captureDate}:${file.fileName.substringBeforeLast('.').lowercase(java.util.Locale.ROOT)}"

internal fun reviewPhotos(files: List<NikonCamera.FileInfo>): List<NikonCamera.FileInfo> {
    val captures = linkedMapOf<String, NikonCamera.FileInfo>()
    for (file in files) {
        if (file.extension !in REVIEW_PHOTO_EXTENSIONS) continue
        val key = reviewCaptureKey(file)
        val previous = captures[key]
        if (previous == null || (file.extension in setOf(".jpg", ".jpeg") &&
                previous.extension !in setOf(".jpg", ".jpeg"))) captures[key] = file
    }
    return captures.values.toList()
}

/**
 * Handles are frozen at open. Metadata is read a page at a time, independently of album filters.
 * Merge each card's newest-first stream by capture time. Finish a whole timestamp group before
 * publishing it, so a RAW on card 1 cannot appear before its JPEG on card 2 has been considered.
 */
internal class RemoteReviewCatalog(
    private val handlesByStorage: List<List<Int>>,
    private val readFile: suspend (Int) -> NikonCamera.FileInfo?,
) {
    private val mutex = Mutex()
    private val cursors = IntArray(handlesByStorage.size)
    private val heads = MutableList<NikonCamera.FileInfo?>(handlesByStorage.size) { null }
    private val published = mutableListOf<NikonCamera.FileInfo>()
    private val publishedKeys = hashSetOf<String>()
    private val pendingGroup = mutableListOf<NikonCamera.FileInfo>()
    var hasMore: Boolean = true
        private set

    private suspend fun peek(): Pair<Int, NikonCamera.FileInfo>? {
        for (slot in handlesByStorage.indices) {
            val handles = handlesByStorage[slot]
            while (heads[slot] == null && cursors[slot] < handles.size) {
                // Advance only after a successful response; a cancelled/failed read remains retryable.
                val file = readFile(handles[cursors[slot]])
                cursors[slot]++
                heads[slot] = file
            }
        }
        val slot = selectNewestFileHeadIndex(heads) ?: return null
        return slot to checkNotNull(heads[slot])
    }

    suspend fun loadNextPage(pageSize: Int = 12): List<NikonCamera.FileInfo> = mutex.withLock {
        require(pageSize > 0)
        val target = published.size + pageSize
        while (hasMore && published.size < target) {
            while (true) {
                val next = peek()
                val first = pendingGroup.firstOrNull()
                if (next == null || (first != null &&
                        (first.captureDate.isNullOrBlank() || next.second.captureDate != first.captureDate))) {
                    reviewPhotos(pendingGroup).forEach { file ->
                        if (publishedKeys.add(reviewCaptureKey(file))) published += file
                    }
                    pendingGroup.clear()
                    if (next == null) hasMore = false
                    break
                }
                pendingGroup += next.second
                heads[next.first] = null
            }
        }
        published.toList()
    }
}
