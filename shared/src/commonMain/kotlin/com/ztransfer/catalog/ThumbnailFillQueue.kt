package com.ztransfer.catalog

/**
 * Returns every file newest-first, while moving an optional capture-day range to the front.
 * Both partitions retain the same stable timestamp order, including the camera's order for ties.
 */
fun <T : CameraCatalogFile> prioritizedThumbnailFiles(
    files: List<T>,
    range: CaptureDayRange?,
): List<T> {
    val ordered = newestFirstCameraFiles(files)
    if (range == null) return ordered
    val prioritized = ArrayList<T>(ordered.size)
    val remaining = ArrayList<T>(ordered.size)
    ordered.forEach { file ->
        if (range.containsCaptureDate(file.captureDate)) prioritized += file else remaining += file
    }
    prioritized.addAll(remaining)
    return prioritized
}

/**
 * Session-local thumbnail work queue. It owns only ordering and retry state; camera requests,
 * decoded images, disk files, coroutine cancellation, and wake-up signals stay platform-side.
 */
class ThumbnailFillQueue<T : CameraCatalogFile> {
    private val priority = ArrayDeque<T>()
    private val regular = ArrayDeque<T>()
    private val pendingHandles = HashSet<Int>()
    private val failed = LinkedHashMap<Int, T>()
    private val settledHandles = HashSet<Int>()
    private var range: CaptureDayRange? = null
    private var seededRevision = -1L

    val pendingCount: Int get() = pendingHandles.size
    val failedCount: Int get() = failed.size
    var revision: Long = 0L
        private set

    fun reset() {
        revision++
        priority.clear()
        regular.clear()
        pendingHandles.clear()
        failed.clear()
        settledHandles.clear()
        range = null
    }

    /** Starts a new enumeration in the same camera session without forgetting proven disk hits. */
    fun beginScan() {
        revision++
        priority.clear()
        regular.clear()
        pendingHandles.clear()
        failed.clear()
    }

    fun markSettled(handle: Int) {
        settledHandles += handle
        failed.remove(handle)
        if (pendingHandles.remove(handle)) {
            priority.removeAll { it.handle == handle }
            regular.removeAll { it.handle == handle }
        }
    }

    /** Drops camera objects that an authoritative handle catalog confirmed no longer exist. */
    fun removeHandles(handles: Set<Int>) {
        if (handles.isEmpty()) return
        priority.removeAll { it.handle in handles }
        regular.removeAll { it.handle in handles }
        pendingHandles.removeAll(handles)
        handles.forEach {
            failed.remove(it)
            settledHandles.remove(it)
        }
    }

    /** Seeds only work not already completed by the platform's scan pipeline. */
    fun seed(files: List<T>, priorityRange: CaptureDayRange?) {
        if (seededRevision == revision) return
        seededRevision = revision
        updatePriorityRange(priorityRange)
        val missing = files.filterNot { file ->
            file.handle in settledHandles || file.handle in pendingHandles || file.handle in failed
        }
        prioritizedThumbnailFiles(missing, priorityRange).forEach(::addLast)
    }

    /** Camera ObjectAdded events are normally newest, so they enter the front of their lane. */
    fun enqueueNew(file: T) {
        if (file.handle in settledHandles || file.handle in pendingHandles || file.handle in failed) {
            return
        }
        pendingHandles += file.handle
        laneFor(file).addFirst(file)
    }

    fun poll(): T? {
        val file = priority.removeFirstOrNull() ?: regular.removeFirstOrNull() ?: return null
        pendingHandles.remove(file.handle)
        return file
    }

    fun returnToFront(file: T, expectedRevision: Long = revision) {
        if (revision != expectedRevision) return
        if (file.handle in settledHandles || file.handle in pendingHandles || file.handle in failed) {
            return
        }
        pendingHandles += file.handle
        laneFor(file).addFirst(file)
    }

    fun markFailed(file: T) {
        if (file.handle !in settledHandles) failed[file.handle] = file
    }

    /** A real platform state change grants failed items one new attempt. */
    fun retryFailed() {
        if (failed.isEmpty()) return
        val retry = failed.values.toList()
        failed.clear()
        prioritizedThumbnailFiles(retry, range).forEach(::addLast)
    }

    /** Reorders only unfinished work. Completed files are never revisited. */
    fun updatePriorityRange(priorityRange: CaptureDayRange?) {
        if (range == priorityRange) return
        range = priorityRange
        val unfinished = ArrayList<T>(pendingHandles.size)
        unfinished.addAll(priority)
        unfinished.addAll(regular)
        priority.clear()
        regular.clear()
        pendingHandles.clear()
        prioritizedThumbnailFiles(unfinished, priorityRange).forEach(::addLast)
    }

    private fun addLast(file: T) {
        if (file.handle in settledHandles || !pendingHandles.add(file.handle)) return
        laneFor(file).addLast(file)
    }

    private fun laneFor(file: T): ArrayDeque<T> =
        if (range?.containsCaptureDate(file.captureDate) == true) priority else regular
}
