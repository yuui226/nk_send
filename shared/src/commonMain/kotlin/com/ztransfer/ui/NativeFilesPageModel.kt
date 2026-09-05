package com.ztransfer.ui

import com.ztransfer.catalog.*
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.ui.screen.*
import com.ztransfer.viewmodel.NativeOriginalFileIndex
import com.ztransfer.viewmodel.NativeOriginalIndexUpdate
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.TimeoutCancellationException
import kotlin.coroutines.resume

interface NativeFilesEnqueueCompletion { fun complete(acceptedCount: Int) }
interface NativeFilesThumbnailCompletion { fun complete(encodedImage: ByteArray?, retryable: Boolean) }

/** UI-thread boundary. The platform owns scanning, camera I/O and the existing queue actor. */
interface NativeFilesPagePlatform {
    fun readBrowsePreferences(): NativeBrowsePreferences?
    fun saveBrowsePreferences(value: NativeBrowsePreferences): Boolean
    fun currentDayKey(): Int
    fun refresh()
    fun enqueue(handles: IntArray, scanSequence: Long, completion: NativeFilesEnqueueCompletion)
    fun thumbnail(file: CameraFileInfo, completion: NativeFilesThumbnailCompletion)
    fun cancelRequests()
}

class NativeFilesPageSnapshot(val connectionId: String, val metadataComplete: Boolean, val changedWhileScanning: Boolean) {
    private var storageIds: List<Int> = emptyList()
    fun setStorageIds(values: IntArray) { storageIds = values.toList() }
    internal fun storageIds(): List<Int> = storageIds.toList()
    private val files = ArrayList<CameraFileInfo>()
    private val handles = HashSet<Int>()
    private var valid = true
    fun addFile(handle: Int, size: Long, name: String, captureDate: String?, isProtected: Boolean, storageIds: IntArray): Boolean {
        if (!handles.add(handle) || name.isEmpty()) { valid = false; return false }
        files += CameraFileInfo(handle, size, name, captureDate, isProtected, storageIds.toSet())
        return true
    }
    internal fun validatedFiles(): List<CameraFileInfo>? = if (valid) files.toList() else null
}

internal enum class NativeFilesNotice { NONE, SCAN_FAILED, INCOMPLETE, CHANGED, INVALID, ENQUEUE_FAILED, PARTIAL_ENQUEUE, PREVIEW_PENDING }
internal data class NativeFilesState(
    val storageIds: List<Int> = emptyList(),
    val files: List<CameraFileInfo> = emptyList(),
    val groups: List<FileGroup> = emptyList(),
    val bursts: List<BurstPhotoGroup> = emptyList(),
    val scanSequence: Long = 0,
    val scanning: Boolean = false,
    val hasSnapshot: Boolean = false,
    val enqueueing: Boolean = false,
    val notice: NativeFilesNotice = NativeFilesNotice.NONE,
)
internal data class NativeFilesImageResult(val bytes: ByteArray?, val retryable: Boolean)
internal data class NativeOriginalsState(val revision: Long = -1, val refreshing: Boolean = false, val failed: Boolean = false) {
    val ready: Boolean get() = revision >= 0
}

/** One camera generation, one existing queue model; no copy of Android's ViewModel or protocol. */
class NativeFilesPageModel(val connectionId: String, val queue: NativeQueuePageModel, platform: NativeFilesPagePlatform) {
    init { require(queue.connectionId == connectionId) }
    private var platform: NativeFilesPagePlatform? = platform
    private var closed = false
    private var previewPlatform: NativePreviewReadPlatform? = null
    private var previewReads: NativePreviewReadSession? = null
    private var nextPreviewSession = 0L
    private var attempt = 0L
    private var currentFiles = emptyMap<Int, CameraFileInfo>()
    private val mutableState = MutableStateFlow(NativeFilesState())
    internal val state = mutableState.asStateFlow()
    private val enqueues = HashSet<CancellableContinuation<Int>>()
    private val images = HashSet<CancellableContinuation<NativeFilesImageResult>>()
    private var originalIndex = NativeOriginalFileIndex()
    private val mutableOriginals = MutableStateFlow(NativeOriginalsState())
    internal val originals = mutableOriginals.asStateFlow()
    private val restoredPreferences = checkNotNull(this.platform).readBrowsePreferences()
    private val initialPreferences = restoredPreferences ?: NativeBrowsePreferences.defaults()
    private val mutableLayout = MutableStateFlow(NativeBrowseLayout(initialPreferences.columns, initialPreferences.collapseBursts))
    internal val layout = mutableLayout.asStateFlow()
    private val mutablePreferencesFailed = MutableStateFlow(restoredPreferences == null)
    internal val preferencesFailed = mutablePreferencesFailed.asStateFlow()
    private val mutableFilters = MutableStateFlow(initialPreferences.criteria())
    internal val filters = mutableFilters.asStateFlow()
    private var lastDayKey = checkNotNull(this.platform).currentDayKey()

    internal fun currentDayKey(): Int = platform?.currentDayKey()?.also { lastDayKey = it } ?: lastDayKey
    internal fun changeFilters(next: SharedPhotoFilterCriteria<CaptureDayRange>): Boolean {
        if (closed || (next.untransferredOnly && !mutableFilters.value.untransferredOnly && !originalIndex.hasSnapshot)) return false
        val snapshot = mutableState.value
        val normalized = next.copy(
            extensions = next.extensions?.toSet(),
            storageSlot = normalizeStorageSlotFilter(next.storageSlot,
                storageFilterSlots(storageIdsBySlot(snapshot.storageIds).keys), snapshot.hasSnapshot),
        )
        if (normalized == mutableFilters.value) return false
        mutableFilters.value = normalized
        persistPreferences()
        return true
    }
    internal fun changeLayout(columns: Int, collapseBursts: Boolean) {
        if (closed) return
        val next = NativeBrowseLayout(com.ztransfer.viewmodel.normalizeThumbnailColumns(columns), collapseBursts)
        if (next == mutableLayout.value) return
        mutableLayout.value = next
        persistPreferences()
    }
    private fun persistPreferences() {
        val layout = mutableLayout.value
        val filter = mutableFilters.value
        val value = NativeBrowsePreferences(layout.columns, layout.collapseBursts, filter.extensions?.toList(),
            filter.protectedOnly, filter.burstOnly, filter.untransferredOnly,
            filter.dateRange?.startDayKey ?: 0, filter.dateRange?.endInclusiveDayKey ?: 0)
        mutablePreferencesFailed.value = platform?.saveBrowsePreferences(value) != true
    }
    internal fun transferredHandlesForFilter(): Set<Int> = if (mutableFilters.value.untransferredOnly) {
        mutableState.value.files.asSequence().filter(::isTransferred).mapTo(HashSet()) { it.handle }
    } else emptySet()

    fun beginOriginalsRefresh() { if (!closed) mutableOriginals.value = mutableOriginals.value.copy(refreshing = true, failed = false) }
    fun publishOriginals(update: NativeOriginalIndexUpdate): Boolean {
        if (closed || !originalIndex.apply(update)) return false
        mutableOriginals.value = NativeOriginalsState(revision = originalIndex.revision)
        return true
    }
    fun originalsRefreshFailed() {
        if (!closed) mutableOriginals.value = mutableOriginals.value.copy(refreshing = false, failed = true)
    }
    internal fun isTransferred(file: CameraFileInfo): Boolean = originalIndex.contains(file, folder = null)

    fun attachPreviewReads(platform: NativePreviewReadPlatform): Boolean {
        if (closed || (previewPlatform != null && previewPlatform !== platform)) return false
        previewPlatform = platform
        return true
    }

    fun beginPreviewReads(): NativePreviewReadSession? {
        val owner = previewPlatform ?: return null
        if (closed || nextPreviewSession == Long.MAX_VALUE) return null
        previewReads?.close()
        val frozenSources = currentFiles.values.mapNotNull { file -> localOriginalSource(file)?.let { file to it } }.toMap()
        return NativePreviewReadSession(++nextPreviewSession, owner,
            isCurrentFile = { file -> !closed && queue.connected.value && currentFiles[file.handle] == file },
            isFrozenLocalSource = { file, source -> !closed && frozenSources[file] == source },
        ).also { previewReads = it }
    }

    internal fun localOriginalSource(file: CameraFileInfo): String? = originalIndex.localLocator(file, folder = null)

    fun beginScan(): Long {
        if (closed || !queue.connected.value || mutableState.value.scanning || mutableState.value.enqueueing) return 0
        attempt++
        mutableState.value = mutableState.value.copy(scanning = true, notice = NativeFilesNotice.NONE)
        return attempt
    }

    fun finishScan(sequence: Long, snapshot: NativeFilesPageSnapshot?): Boolean {
        if (closed || sequence != attempt || !mutableState.value.scanning) return false
        val files = snapshot?.validatedFiles()
        val notice = when {
            snapshot == null -> NativeFilesNotice.SCAN_FAILED
            snapshot.connectionId != connectionId || files == null -> NativeFilesNotice.INVALID
            !snapshot.metadataComplete -> NativeFilesNotice.INCOMPLETE
            snapshot.changedWhileScanning -> NativeFilesNotice.CHANGED
            !queue.connected.value -> NativeFilesNotice.SCAN_FAILED
            else -> NativeFilesNotice.NONE
        }
        if (notice != NativeFilesNotice.NONE) {
            mutableState.value = mutableState.value.copy(scanning = false, notice = notice)
            return false // Never treat partial/failed/event-raced scans as deletion evidence.
        }
        val complete = checkNotNull(files)
        currentFiles = complete.associateBy { it.handle }
        mutableState.value = NativeFilesState(
            storageIds = checkNotNull(snapshot).storageIds(),
            files = complete,
            groups = groupCameraFilesByDate(complete).map { FileGroup(it.date, it.files) },
            bursts = detectCameraBurstGroups(complete).map { BurstPhotoGroup(it.id, it.files) },
            scanSequence = sequence, hasSnapshot = true,
        )
        changeFilters(mutableFilters.value) // Only the now-complete storage list may normalize a stale slot.
        return true
    }

    internal fun refresh() { if (!closed) platform?.refresh() }
    internal fun previewPending() { if (!closed) mutableState.value = mutableState.value.copy(notice = NativeFilesNotice.PREVIEW_PENDING) }

    internal suspend fun enqueue(files: List<CameraFileInfo>): Int {
        val owner = platform ?: throw CancellationException("Files page closed")
        val before = mutableState.value
        if (closed || before.scanning || before.enqueueing || files.isEmpty()) return 0
        if (!queue.connected.value || files.any { currentFiles[it.handle] != it } ||
            files.map { it.handle }.toSet().size != files.size) {
            mutableState.value = before.copy(notice = NativeFilesNotice.ENQUEUE_FAILED)
            if (!queue.connected.value) queue.showConnectionHelp()
            return 0
        }
        mutableState.value = before.copy(enqueueing = true, notice = NativeFilesNotice.NONE)
        var pending: CancellableContinuation<Int>? = null
        try {
            val accepted = withTimeout(15_000L) {
                suspendCancellableCoroutine<Int> { continuation ->
                    pending = continuation; enqueues += continuation
                    owner.enqueue(files.map { it.handle }.toIntArray(), before.scanSequence, object : NativeFilesEnqueueCompletion {
                        override fun complete(acceptedCount: Int) {
                            if (!closed && continuation.isActive) continuation.resume(acceptedCount.takeIf { it in 0..files.size } ?: 0)
                        }
                    })
                }
            }
            mutableState.value = mutableState.value.copy(notice = when (accepted) {
                files.size -> NativeFilesNotice.NONE
                0 -> NativeFilesNotice.ENQUEUE_FAILED
                else -> NativeFilesNotice.PARTIAL_ENQUEUE
            })
            return accepted
        } catch (timeout: TimeoutCancellationException) {
            if (!closed) mutableState.value = mutableState.value.copy(notice = NativeFilesNotice.ENQUEUE_FAILED)
            throw timeout
        } finally {
            pending?.let(enqueues::remove)
            if (!closed) mutableState.value = mutableState.value.copy(enqueueing = false)
        }
    }

    internal suspend fun thumbnail(file: CameraFileInfo): NativeFilesImageResult {
        val owner = platform ?: throw CancellationException("Files page closed")
        if (!queue.connected.value || currentFiles[file.handle] != file) return NativeFilesImageResult(null, false)
        var pending: CancellableContinuation<NativeFilesImageResult>? = null
        return try {
            withTimeout(15_000L) {
                suspendCancellableCoroutine { continuation ->
                    pending = continuation; images += continuation
                    owner.thumbnail(file, object : NativeFilesThumbnailCompletion {
                        override fun complete(encodedImage: ByteArray?, retryable: Boolean) {
                            if (!closed && continuation.isActive) continuation.resume(NativeFilesImageResult(
                                encodedImage?.takeIf { it.size <= 4 * 1024 * 1024 }, retryable))
                        }
                    })
                }
            }
        } finally { pending?.let(images::remove) }
    }

    fun close() {
        if (closed) return
        closed = true
        previewReads?.close(); previewReads = null; previewPlatform = null
        enqueues.toList().forEach { it.cancel() }; enqueues.clear()
        images.toList().forEach { it.cancel() }; images.clear()
        val owner = platform; platform = null
        owner?.cancelRequests()
        queue.close()
        currentFiles = emptyMap()
        mutableState.value = NativeFilesState()
        mutableOriginals.value = NativeOriginalsState()
        originalIndex = NativeOriginalFileIndex()
        mutableFilters.value = SharedPhotoFilterCriteria()
    }
}
