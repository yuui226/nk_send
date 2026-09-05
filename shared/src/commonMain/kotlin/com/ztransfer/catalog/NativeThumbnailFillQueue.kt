package com.ztransfer.catalog

import com.ztransfer.protocol.CameraFileInfo

class NativeThumbnailFillRequest internal constructor(val revision: Long, val file: CameraFileInfo)

/** Thin actor-owned Native boundary; all ordering, lanes, failure retry and requeue rules stay in ThumbnailFillQueue. */
class NativeThumbnailFillQueue {
    private val queue = ThumbnailFillQueue<CameraFileInfo>()
    private var range: CaptureDayRange? = null
    private var active: NativeThumbnailFillRequest? = null
    val pendingCount: Int get() = queue.pendingCount
    val failedCount: Int get() = queue.failedCount

    fun replace(files: List<CameraFileInfo>): Boolean {
        if (files.any { it.fileName.isEmpty() || it.size < 0 } || files.map { it.handle }.toSet().size != files.size) return false
        val copied = files.map { it.copy(storageIds = it.storageIds.toSet()) }
        queue.reset()
        active = null
        // Native scans have not yet done Android's per-batch disk checks. Recheck each disk entry after a full scan,
        // including after the OS has purged Caches; do not preserve unverified in-memory "settled" disk claims.
        queue.seed(copied, range)
        return true
    }

    fun setPriorityRange(startDay: Int, endDay: Int): Boolean {
        val next = try { CaptureDayRange.between(startDay, endDay) } catch (_: IllegalArgumentException) { null }
        if (next == range) return false
        range = next
        queue.updatePriorityRange(next)
        queue.retryFailed()
        return true
    }

    fun next(): NativeThumbnailFillRequest? {
        if (active != null) return null
        val file = queue.poll() ?: return null
        return NativeThumbnailFillRequest(queue.revision, file).also { active = it }
    }
    fun isCurrent(request: NativeThumbnailFillRequest): Boolean = active === request && request.revision == queue.revision
    fun settled(request: NativeThumbnailFillRequest): Boolean = finish(request) { queue.markSettled(request.file.handle) }
    fun failed(request: NativeThumbnailFillRequest): Boolean = finish(request) { queue.markFailed(request.file) }
    fun returnToFront(request: NativeThumbnailFillRequest): Boolean = finish(request) { queue.returnToFront(request.file, request.revision) }
    fun retryFailed() { queue.retryFailed() }
    fun clear() { queue.reset(); active = null; range = null }
    private inline fun finish(request: NativeThumbnailFillRequest, action: () -> Unit): Boolean {
        if (!isCurrent(request)) return false
        active = null
        action()
        return true
    }
}
