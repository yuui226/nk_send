package com.ztransfer.viewmodel

import com.ztransfer.protocol.NikonCamera
import com.ztransfer.protocol.selectNewestFileHeadIndex
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

private val REVIEW_PHOTO_EXTENSIONS = setOf(".jpg", ".jpeg", ".nef", ".nrw", ".tif", ".tiff", ".heif", ".hif", ".heic")

private val REVIEW_JPEG_EXTENSIONS = setOf(".jpg", ".jpeg")
private val REVIEW_RAW_EXTENSIONS = setOf(".nef", ".nrw")

private fun reviewStem(file: NikonCamera.FileInfo) =
    file.fileName.substringBeforeLast('.').lowercase(java.util.Locale.ROOT)

// PTP and EXIF can describe the same capture with different subsecond precision.
private fun reviewCaptureDate(file: NikonCamera.FileInfo): String? =
    file.captureDate?.trim()?.takeIf { it.isNotEmpty() }?.take(15)

private fun reviewCaptureDate(files: List<NikonCamera.FileInfo>): String? =
    files.mapNotNull(::reviewCaptureDate).maxByOrNull { it.length }

private fun reviewDatesCompatible(first: String?, second: String?): Boolean =
    first == null || second == null || first.startsWith(second) || second.startsWith(first)

private fun reviewCompanions(first: NikonCamera.FileInfo, second: NikonCamera.FileInfo): Boolean {
    if (reviewStem(first) != reviewStem(second)) return false
    val firstDate = reviewCaptureDate(first)
    val secondDate = reviewCaptureDate(second)
    if (!reviewDatesCompatible(firstDate, secondDate)) return false
    return (first.extension in REVIEW_JPEG_EXTENSIONS && second.extension in REVIEW_RAW_EXTENSIONS) ||
        (first.extension in REVIEW_RAW_EXTENSIONS && second.extension in REVIEW_JPEG_EXTENSIONS)
}

/** One page retains its source formats, prefers JPEG for FHD and keeps its first object's key. */
internal data class RemoteReviewPhoto(val files: List<NikonCamera.FileInfo>) {
    val key: Int get() = files.first().handle
    val file: NikonCamera.FileInfo get() =
        files.firstOrNull { it.extension in REVIEW_JPEG_EXTENSIONS } ?: files.first()
    val pairedRawExtension: String? get() = if (file.extension in REVIEW_JPEG_EXTENSIONS)
        files.firstOrNull { it.extension in REVIEW_RAW_EXTENSIONS }?.extension else null
    val captureDate: String? get() = reviewCaptureDate(files)

    fun canPair(file: NikonCamera.FileInfo): Boolean {
        val date = reviewCaptureDate(file)
        if (!reviewDatesCompatible(captureDate, date)) return false
        // With no timestamp, merge only complementary formats, never two same-name JPEGs/RAWs.
        val family = when (file.extension) {
            in REVIEW_JPEG_EXTENSIONS -> REVIEW_JPEG_EXTENSIONS
            in REVIEW_RAW_EXTENSIONS -> REVIEW_RAW_EXTENSIONS
            else -> return false
        }
        return files.none { it.extension in family } && files.any { reviewCompanions(it, file) }
    }
}

/** Append-only page positions: a later companion enriches its existing page, never inserts a duplicate. */
private class ReviewPhotos {
    private val photos = mutableListOf<RemoteReviewPhoto>()
    private val indicesByStem = mutableMapOf<String, MutableList<Int>>()
    private val handles = hashSetOf<Int>()
    val size: Int get() = photos.size
    fun snapshot(): List<RemoteReviewPhoto> = photos.toList()

    fun addAll(files: List<NikonCamera.FileInfo>) {
        for (file in files) {
            if (file.extension !in REVIEW_PHOTO_EXTENSIONS || !handles.add(file.handle)) continue
            val indices = indicesByStem.getOrPut(reviewStem(file)) { mutableListOf() }
            val date = reviewCaptureDate(file)
            val dated = if (date == null) emptyList() else indices.filter { photos[it].captureDate == date }
            val target = if (dated.isNotEmpty()) dated.singleOrNull()
                else indices.filter { photos[it].canPair(file) }.singleOrNull()
            if (target == null) {
                indices += photos.size
                photos += RemoteReviewPhoto(listOf(file))
            } else {
                photos[target] = photos[target].copy(files = photos[target].files + file)
            }
        }
    }
}

internal fun reviewPhotos(files: List<NikonCamera.FileInfo>): List<RemoteReviewPhoto> =
    ReviewPhotos().apply { addAll(files) }.snapshot()

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
    private val published = ReviewPhotos()
    private val pendingGroup = mutableListOf<NikonCamera.FileInfo>()
    var hasMore: Boolean = true
        private set

    private fun pendingCompanion(file: NikonCamera.FileInfo): Boolean {
        val date = reviewCaptureDate(pendingGroup)
        val nextDate = reviewCaptureDate(file)
        return reviewDatesCompatible(date, nextDate) &&
            pendingGroup.any { reviewCompanions(it, file) }
    }

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
        // A missing timestamp on one card must not postpone the other half past this page.
        val partner = heads.indexOfFirst { head -> head != null && pendingCompanion(head) }
        val slot = partner.takeIf { it >= 0 } ?: selectNewestFileHeadIndex(heads) ?: return null
        return slot to checkNotNull(heads[slot])
    }

    suspend fun loadNextPage(pageSize: Int = 12): List<RemoteReviewPhoto> = mutex.withLock {
        require(pageSize > 0)
        val target = published.size + pageSize
        while (hasMore && published.size < target) {
            while (true) {
                val next = peek()
                val date = reviewCaptureDate(pendingGroup)
                val sameGroup = next != null && (pendingGroup.isEmpty() ||
                    (date != null && date == reviewCaptureDate(next.second)) || pendingCompanion(next.second))
                if (!sameGroup) {
                    published.addAll(pendingGroup)
                    pendingGroup.clear()
                    if (next == null) hasMore = false
                    break
                }
                val (slot, file) = checkNotNull(next)
                pendingGroup += file
                heads[slot] = null
            }
        }
        published.snapshot()
    }
}
