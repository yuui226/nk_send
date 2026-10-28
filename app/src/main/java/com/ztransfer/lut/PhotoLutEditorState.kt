package com.ztransfer.lut

import android.net.Uri
import com.ztransfer.presets.PresetIoQueue
import com.ztransfer.presets.PresetIoTicket
import androidx.compose.runtime.*
import com.ztransfer.R
import com.ztransfer.filter.PhotoFilterSelection
import com.ztransfer.filter.LutAdjustments
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Photo editor draft. File parsing and snapshot IO use the same bounded queue as monitor LUT. */
@Stable
internal class PhotoLutEditorState(
    val role: String,
    val store: PhotoLutStore,
    private val source: LutSource,
    private val scope: CoroutineScope,
    initial: PhotoFilterSelection?,
    initialUri: String?,
    private val onSelected: () -> Unit,
    private val notice: (Int) -> Unit,
) {
    init { requirePhotoLutRole(role) }
    var selection by mutableStateOf(initial.takeIf { store.isSelectionCurrent(role, it, initialUri) }); private set
    var pendingUri by mutableStateOf<Uri?>(null); private set
    var selectedUri by mutableStateOf(initialUri?.let(Uri::parse).takeIf { selection != null }); private set
    var files by mutableStateOf<List<LutFile>>(emptyList()); private set
    var folder by mutableStateOf(store.folders.folder); private set
    var failure by mutableStateOf<LutFolderFailure?>(null); private set
    var loading by mutableStateOf(false); private set
    var loadingSelection by mutableStateOf(false); private set
    var favorites by mutableStateOf(store.favorites()); private set
    private var ticket: PresetIoTicket? = null
    private var timer: Job? = null
    private var generation = 0L
    private var folderRevision = store.folderRevision
    private var disposed = false
    private val folderObserver = store.observeFolderChanges { synchronizeFolder() }

    private fun synchronizeFolder() {
        if (disposed) return
        val current = store.folders.folder
        val currentRevision = store.folderRevision
        if (current == folder && currentRevision == folderRevision) return
        off()
        folder = current
        folderRevision = currentRevision
        files = emptyList()
        favorites = store.favorites()
        failure = null
    }

    fun reset(value: PhotoFilterSelection?, uri: String?) {
        synchronizeFolder()
        cancel()
        selection = value.takeIf { store.isSelectionCurrent(role, it, uri) }
        selectedUri = uri?.let(Uri::parse).takeIf { selection != null }
    }
    fun cancelPending() { cancel() }
    fun off() { cancel(); selection = null; selectedUri = null }
    fun strength(value: Int) {
        synchronizeFolder()
        selection = selection?.copy(intensityPercent = value)
        selection?.preset?.id?.removePrefix("cube:")?.takeIf(PHOTO_LUT_DIGEST_PATTERN::matches)
            ?.let { digest -> store.rememberIntensity(role, digest, selectedUri?.toString(), value) }
    }
    fun adjustments(value: LutAdjustments) {
        synchronizeFolder()
        val current = selection ?: return
        val normalized = value.normalized()
        selection = current.copy(lutAdjustments = normalized)
        current.preset.id.removePrefix("cube:").takeIf(PHOTO_LUT_DIGEST_PATTERN::matches)
            ?.let { store.rememberAdjustments(role, it, normalized) }
    }
    fun favorite() {
        synchronizeFolder()
        selectedUri?.let { store.toggleFavorite(it.toString()); favorites = store.favorites() }
    }
    fun refresh() {
        synchronizeFolder()
        favorites = store.favorites()
        folder = store.folders.folder
        folder?.let { scan(it, false) }
    }
    fun folderPicked(uri: Uri) = scan(uri, true)
    fun choose(uri: Uri?) {
        synchronizeFolder()
        if (uri == null) { off(); return }
        val file = files.find { it.uri == uri } ?: return
        val id = begin()
        loadingSelection = true
        pendingUri = uri
        ticket = PresetIoQueue.submit({ signal ->
            val table = source.read(file, signal)
            signal.throwIfCanceled()
            store.snapshot(role, file, table)
        }) { result ->
            if (!valid(id)) return@submit
            finish()
            result.fold(onSuccess = {
                selection = it; selectedUri = uri
                onSelected()
                PresetIoQueue.cleanup { store.prune() }
            }, onFailure = { error ->
                notice(when ((error as? LutException)?.reason) {
                    LutFailure.INVALID -> R.string.lut_invalid
                    LutFailure.UNSUPPORTED -> R.string.lut_unsupported
                    LutFailure.TOO_LARGE -> R.string.lut_too_large
                    else -> R.string.lut_read_failed
                })
            })
        }
    }
    private fun scan(uri: Uri, replacing: Boolean) {
        val id = begin {
            if (!replacing) failure = LutFolderFailure.READ
        }
        ticket = PresetIoQueue.submit({ source.scan(uri, replacing, it) },
            discard = { if (it.getOrNull()?.acquired == true) source.releaseGrant(uri) }) { result ->
            if (!valid(id)) return@submit
            finish()
            result.fold(onSuccess = { snapshot ->
                val previous = folder
                val previousOwned = store.folders.ownsFolderGrant
                if (replacing && previous != uri) {
                    store.folders.replaceFolder(uri, snapshot.acquired)
                    folder = uri
                    off()
                    if (previous != null && previousOwned) PresetIoQueue.cleanup { source.releaseGrant(previous) }
                } else if (snapshot.acquired) store.folders.markFolderGrantOwned()
                files = snapshot.files
                failure = null
                if (selectedUri != null && files.none { it.uri == selectedUri }) off()
            }, onFailure = {
                val reason = (it as? LutFolderException)?.reason ?: LutFolderFailure.READ
                if (!replacing) {
                    failure = reason
                    if (reason == LutFolderFailure.MISSING || reason == LutFolderFailure.DENIED) {
                        files = emptyList()
                        off()
                    }
                }
                notice(folderMessage(reason))
            })
        }
    }
    private fun begin(onTimeout: () -> Unit = {}): Long {
        cancel(); loading = true
        val id = generation
        timer = scope.launch {
            delay(10_000)
            if (valid(id)) { cancel(); onTimeout(); notice(R.string.lut_read_timeout) }
        }
        return id
    }
    private fun valid(id: Long) = !disposed && generation == id
    private fun finish() { timer?.cancel(); timer = null; ticket = null; loading = false; loadingSelection = false; pendingUri = null }
    private fun cancel() { generation++; ticket?.cancel(); ticket = null; finish() }
    fun close() { disposed = true; folderObserver.close(); cancel() }
}
