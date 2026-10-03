package com.ztransfer.lut

import android.net.Uri
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
    val store: PhotoLutStore,
    private val source: LutSource,
    private val scope: CoroutineScope,
    initial: PhotoFilterSelection?,
    initialUri: String?,
    private val onSelected: () -> Unit,
    private val notice: (Int) -> Unit,
) {
    var selection by mutableStateOf(initial); private set
    var pendingUri by mutableStateOf<Uri?>(null); private set
    var selectedUri by mutableStateOf(initialUri?.let(Uri::parse)); private set
    var files by mutableStateOf<List<LutFile>>(emptyList()); private set
    var folder by mutableStateOf(store.folders.folder); private set
    var failure by mutableStateOf<LutFolderFailure?>(null); private set
    var loading by mutableStateOf(false); private set
    var loadingSelection by mutableStateOf(false); private set
    var favorites by mutableStateOf(store.favorites()); private set
    private var ticket: LutIoQueue.Ticket? = null
    private var timer: Job? = null
    private var generation = 0L
    private var disposed = false

    fun reset(value: PhotoFilterSelection?, uri: String?) {
        cancel(); selection = value; selectedUri = uri?.let(Uri::parse)
    }
    fun cancelPending() { cancel() }
    fun off() { cancel(); selection = null; selectedUri = null }
    fun strength(value: Int) {
        selection = selection?.copy(intensityPercent = value)
        selection?.preset?.id?.removePrefix("cube:")?.takeIf { it.matches(Regex("[a-f0-9]{64}")) }
            ?.let { digest -> store.rememberIntensity(digest, selectedUri?.toString(), value) }
            ?: selectedUri?.let { store.rememberIntensity(it.toString(), value) }
    }
    fun adjustments(value: LutAdjustments) {
        val current = selection ?: return
        val normalized = value.normalized()
        selection = current.copy(lutAdjustments = normalized)
        current.preset.id.removePrefix("cube:").takeIf { it.matches(Regex("[a-f0-9]{64}")) }
            ?.let { store.rememberAdjustments(it, normalized) }
    }
    fun favorite() {
        selectedUri?.let { store.toggleFavorite(it.toString()); favorites = store.favorites() }
    }
    fun refresh() {
        favorites = store.favorites()
        folder = store.folders.folder
        folder?.let { scan(it, false) }
    }
    fun folderPicked(uri: Uri) = scan(uri, true)
    fun choose(uri: Uri?) {
        if (uri == null) { off(); return }
        val file = files.find { it.uri == uri } ?: return
        val id = begin()
        loadingSelection = true
        pendingUri = uri
        ticket = LutIoQueue.submit({ signal ->
            val table = source.read(file, signal)
            signal.throwIfCanceled()
            store.snapshot(file, table)
        }) { result ->
            if (!valid(id)) return@submit
            finish()
            result.fold(onSuccess = {
                selection = it; selectedUri = uri
                onSelected()
                LutIoQueue.cleanup { store.prune() }
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
        ticket = LutIoQueue.submit({ source.scan(uri, replacing, it) },
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
                    if (previous != null && previousOwned) LutIoQueue.cleanup { source.releaseGrant(previous) }
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
    fun close() { disposed = true; cancel() }
}
