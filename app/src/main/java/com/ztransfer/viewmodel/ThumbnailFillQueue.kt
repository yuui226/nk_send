package com.ztransfer.viewmodel

import com.ztransfer.protocol.NikonCamera

/**
 * Session-local work queue for the post-scan thumbnail fill.
 *
 * A handle is settled only after its thumbnail is present on disk (or the camera explicitly reports
 * that it has no thumbnail). Transient failures stay separate from pending work so they cannot form a
 * hot retry loop; the owner promotes them only after a later external wake-up.
 */
internal class ThumbnailFillQueue {
    private val priority = ArrayDeque<NikonCamera.FileInfo>()
    private val regular = ArrayDeque<NikonCamera.FileInfo>()
    private val pendingHandles = HashSet<Int>()
    private val failed = LinkedHashMap<Int, NikonCamera.FileInfo>()
    private val settledHandles = HashSet<Int>()
    private var range: PhotoDateRange? = null
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

    /** Seeds only work not already completed by the 12-item scan pipeline. */
    fun seed(files: List<NikonCamera.FileInfo>, priorityRange: PhotoDateRange?) {
        if (seededRevision == revision) return
        seededRevision = revision
        updatePriorityRange(priorityRange)
        val missing = files.filterNot { file ->
            file.handle in settledHandles || file.handle in pendingHandles || file.handle in failed
        }
        prioritizedThumbnailFiles(missing, priorityRange).forEach(::addLast)
    }

    /** Camera ObjectAdded events are normally newest, so they belong at the front of their lane. */
    fun enqueueNew(file: NikonCamera.FileInfo) {
        if (file.handle in settledHandles || file.handle in pendingHandles || file.handle in failed) return
        pendingHandles += file.handle
        laneFor(file).addFirst(file)
    }

    fun poll(): NikonCamera.FileInfo? {
        val file = priority.removeFirstOrNull() ?: regular.removeFirstOrNull() ?: return null
        pendingHandles.remove(file.handle)
        return file
    }

    fun returnToFront(file: NikonCamera.FileInfo, expectedRevision: Long = revision) {
        if (revision != expectedRevision) return
        if (file.handle in settledHandles || file.handle in pendingHandles || file.handle in failed) return
        pendingHandles += file.handle
        laneFor(file).addFirst(file)
    }

    fun markFailed(file: NikonCamera.FileInfo) {
        if (file.handle !in settledHandles) failed[file.handle] = file
    }

    /** A real state change grants failed items one new attempt; it never retries them in-place. */
    fun retryFailed() {
        if (failed.isEmpty()) return
        val retry = failed.values.toList()
        failed.clear()
        prioritizedThumbnailFiles(retry, range).forEach(::addLast)
    }

    /** Reorders only unfinished work. Completed photos are never revisited. */
    fun updatePriorityRange(priorityRange: PhotoDateRange?) {
        if (range == priorityRange) return
        range = priorityRange
        val unfinished = ArrayList<NikonCamera.FileInfo>(pendingHandles.size)
        unfinished.addAll(priority)
        unfinished.addAll(regular)
        priority.clear()
        regular.clear()
        pendingHandles.clear()
        prioritizedThumbnailFiles(unfinished, priorityRange).forEach(::addLast)
    }

    private fun addLast(file: NikonCamera.FileInfo) {
        if (file.handle in settledHandles || !pendingHandles.add(file.handle)) return
        laneFor(file).addLast(file)
    }

    private fun laneFor(file: NikonCamera.FileInfo): ArrayDeque<NikonCamera.FileInfo> =
        if (range?.containsCaptureDate(file.captureDate) == true) priority else regular
}
