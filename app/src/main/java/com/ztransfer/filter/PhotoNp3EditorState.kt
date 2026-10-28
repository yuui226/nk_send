package com.ztransfer.filter

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.os.CancellationSignal
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.ztransfer.R
import com.ztransfer.presets.PresetFile
import com.ztransfer.presets.PresetFolderException
import com.ztransfer.presets.PresetFolderFailure
import com.ztransfer.presets.PresetFolderOwner
import com.ztransfer.presets.PresetFolderRepository
import com.ztransfer.presets.PresetFolderSnapshot
import com.ztransfer.presets.PresetIoQueue
import com.ztransfer.presets.PresetIoTicket
import com.ztransfer.presets.presetFolderMessage
import com.ztransfer.presets.retainSharedPresetFolderGrant
import java.io.FileNotFoundException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal interface PhotoNp3Source {
    suspend fun scan(uri: Uri, replacing: Boolean, signal: CancellationSignal): PresetFolderSnapshot
    suspend fun read(file: PresetFile, signal: CancellationSignal): ParsedPhotoNp3
    fun releaseGrant(uri: Uri)
}

private class PhotoNp3FolderSource(context: Context) : PhotoNp3Source {
    private val app = context.applicationContext
    private val resolver: ContentResolver = app.contentResolver
    private val repository = PresetFolderRepository(resolver, ".np3") {
        retainSharedPresetFolderGrant(app, PresetFolderOwner.PHOTO_NP3, it)
    }

    override suspend fun scan(uri: Uri, replacing: Boolean, signal: CancellationSignal) =
        repository.scan(uri, replacing, signal)

    override fun releaseGrant(uri: Uri) = repository.releaseGrant(uri)

    override suspend fun read(file: PresetFile, signal: CancellationSignal): ParsedPhotoNp3 =
        withContext(Dispatchers.IO) {
            val coroutine = currentCoroutineContext()
            coroutine.ensureActive()
            signal.throwIfCanceled()
            // A known URI is only an identity hint. Always read again so edited files take effect.
            resolver.openAssetFileDescriptor(file.uri, "r", signal)?.use { descriptor ->
                descriptor.createInputStream().use { input ->
                    PhotoNp3Parser.read(input) {
                        coroutine.ensureActive()
                        signal.throwIfCanceled()
                    }
                }
            } ?: throw FileNotFoundException(file.name)
        }
}

/** Directory/source draft only. The owning editor commits its effect and strength independently. */
@Stable
internal class PhotoNp3EditorState internal constructor(
    val store: PhotoNp3Store,
    private val source: PhotoNp3Source,
    role: String,
    initialPreset: PhotoFilterPreset?,
    private val scope: CoroutineScope,
    private val onSelected: (preset: PhotoFilterPreset, explicit: Boolean) -> Unit,
    private val onUnavailable: () -> Unit,
    private val notice: (Int) -> Unit,
    private val selectionAllowed: () -> Boolean = { true },
) {
    constructor(
        context: Context,
        role: String,
        initialPreset: PhotoFilterPreset?,
        scope: CoroutineScope,
        onSelected: (preset: PhotoFilterPreset, explicit: Boolean) -> Unit,
        onUnavailable: () -> Unit,
        notice: (Int) -> Unit,
        selectionAllowed: () -> Boolean = { true },
    ) : this(PhotoNp3Store(context), PhotoNp3FolderSource(context), role, initialPreset,
        scope, onSelected, onUnavailable, notice, selectionAllowed)

    var folder by mutableStateOf(store.folders.folder); private set
    var files by mutableStateOf<List<PresetFile>>(emptyList()); private set
    var failure by mutableStateOf<PresetFolderFailure?>(null); private set
    var loading by mutableStateOf(false); private set
    var loadingSelection by mutableStateOf(false); private set
    var pendingUri by mutableStateOf<Uri?>(null); private set
    var selectedPreset by mutableStateOf(initialPreset); private set
    var selectedUri by mutableStateOf(store.uri(role)
        ?.takeIf { initialPreset != null && store.savedId(role) == initialPreset.id }?.let(Uri::parse)); private set
    private var sourcePresetIds by mutableStateOf<Map<Uri, String>>(emptyMap())
    private var ticket: PresetIoTicket? = null
    private var timer: Job? = null
    private var generation = 0L
    private var closed = false
    private val folderObserver = store.observeFolderChanges {
        val current = store.folders.folder
        if (!closed && folder != current) {
            val replaced = folder != null
            cancelPending()
            folder = current
            files = emptyList()
            sourcePresetIds = emptyMap()
            failure = null
            if (replaced) {
                val custom = selectedPreset?.id?.let(PhotoNp3SnapshotCodec::isCustomId) == true
                selectedUri = null
                if (custom) {
                    selectedPreset = null
                    onUnavailable()
                }
            }
        }
    }

    fun knownPresetId(uri: Uri): String? = sourcePresetIds[uri]
    fun sourceFor(presetId: String?): String? = selectedUri?.toString()
        ?.takeIf { presetId != null && selectedPreset?.id == presetId }

    /** Synchronize an external built-in/off change and invalidate any older provider result. */
    fun resetSelection(preset: PhotoFilterPreset?, uri: String? = null) {
        val retainedUri = uri?.let(Uri::parse) ?: selectedUri.takeIf { preset?.id == selectedPreset?.id }
        cancelPending()
        selectedPreset = preset
        selectedUri = retainedUri.takeIf { preset != null }
    }

    fun off() {
        cancelPending()
        selectedPreset = null
        selectedUri = null
    }

    fun refresh() {
        if (closed || loading) return
        val currentFolder = store.folders.folder ?: return
        scan(currentFolder, replacing = false)
    }

    fun folderPicked(uri: Uri) { if (!closed) scan(uri, replacing = true) }
    fun choose(uri: Uri) { files.firstOrNull { it.uri == uri }?.let(::choose) }
    fun choose(file: PresetFile) {
        if (closed || files.none { it.uri == file.uri }) return
        read(file, refreshed = false)
    }

    private data class ScanResult(val folder: PresetFolderSnapshot, val sources: Map<Uri, String>)

    private suspend fun scanWithHints(uri: Uri, replacing: Boolean, signal: CancellationSignal): ScanResult {
        val snapshot = source.scan(uri, replacing, signal)
        try {
            val hints = store.knownPresetIds(snapshot.files.map { it.uri.toString() }, signal::throwIfCanceled)
            val sources = snapshot.files.mapNotNull { file ->
                signal.throwIfCanceled()
                hints[file.uri.toString()]?.let { file.uri to it }
            }.toMap()
            return ScanResult(snapshot, sources)
        } catch (failure: Throwable) {
            // A cancellation/error after enumeration still owns its newly acquired grant.
            // No result reaches the queue's discard callback in that case.
            if (snapshot.acquired) source.releaseGrant(uri)
            throw failure
        }
    }

    private fun scan(uri: Uri, replacing: Boolean) {
        val id = begin {
            if (!replacing) failure = PresetFolderFailure.READ
        }
        ticket = PresetIoQueue.submit({ scanWithHints(uri, replacing, it) },
            discard = { if (it.getOrNull()?.folder?.acquired == true) source.releaseGrant(uri) }) { result ->
            if (!valid(id)) return@submit
            finish()
            if (!selectionAllowed()) {
                if (result.getOrNull()?.folder?.acquired == true) {
                    PresetIoQueue.cleanup { source.releaseGrant(uri) }
                }
                return@submit
            }
            result.fold(onSuccess = { scanned ->
                val snapshot = scanned.folder
                val previous = store.folders.folder
                val owned = store.folders.ownsFolderGrant
                if (replacing) {
                    store.folders.replaceFolder(uri, snapshot.acquired || (previous == uri && owned))
                    if (previous != null && previous != uri && owned) {
                        PresetIoQueue.cleanup { source.releaseGrant(previous) }
                    }
                } else if (snapshot.acquired) store.folders.markFolderGrantOwned()
                folder = uri
                files = snapshot.files
                sourcePresetIds = if (replacing && previous != null && previous != uri) emptyMap() else scanned.sources
                failure = null
                val selectedSource = selectedUri
                if (selectedSource != null) {
                    val current = files.firstOrNull { it.uri == selectedSource }
                    if (current == null) {
                        // Only a successful, complete listing confirms deletion. Saved role data
                        // and per-filter memories are intentionally left to the owning editor.
                        off()
                        onUnavailable()
                    } else read(current, refreshed = true)
                }
            }, onFailure = { error ->
                val reason = (error as? PresetFolderException)?.reason ?: PresetFolderFailure.READ
                if (!replacing) failure = reason
                // Temporary failures never erase the previous list or a private effect recipe.
                notice(presetFolderMessage(reason))
            })
        }
    }

    private fun read(file: PresetFile, refreshed: Boolean) {
        val id = begin()
        loadingSelection = true
        pendingUri = file.uri
        ticket = PresetIoQueue.submit({ signal -> source.read(file, signal).also { signal.throwIfCanceled() } }) { result ->
            if (!valid(id)) return@submit
            finish()
            // A retained pager page can become inactive before its cancellation effect runs.
            // Check the live owner before replacing either the draft or its source identity.
            if (!selectionAllowed()) return@submit
            result.fold(onSuccess = { parsed ->
                val unchanged = selectedPreset?.id == parsed.preset.id && selectedUri == file.uri
                store.rememberSource(file.uri.toString(), parsed.sourceSha256, parsed.preset.id)
                sourcePresetIds = sourcePresetIds + (file.uri to parsed.preset.id)
                if (!unchanged) selectedPreset = parsed.preset
                selectedUri = file.uri
                // Returning from the file manager must not reset an unsaved strength detent
                // when the bytes are unchanged. A changed recipe still reaches every owner.
                if (!refreshed || !unchanged) onSelected(checkNotNull(selectedPreset), !refreshed)
            }, onFailure = { error ->
                notice(when ((error as? PhotoNp3Exception)?.reason) {
                    PhotoNp3Failure.INVALID -> R.string.photo_np3_invalid
                    PhotoNp3Failure.UNSUPPORTED -> R.string.photo_np3_unsupported
                    PhotoNp3Failure.TOO_LARGE -> R.string.photo_np3_too_large
                    else -> R.string.photo_np3_read_failed
                })
            })
        }
    }

    private fun begin(onTimeout: () -> Unit = {}): Long {
        cancelPending()
        loading = true
        val id = generation
        timer = scope.launch {
            delay(10_000)
            if (valid(id)) {
                cancelPending()
                onTimeout()
                notice(R.string.photo_np3_read_timeout)
            }
        }
        return id
    }

    private fun valid(id: Long) = !closed && generation == id
    private fun finish() {
        timer?.cancel(); timer = null; ticket = null
        loading = false; loadingSelection = false; pendingUri = null
    }
    fun cancelPending() { generation++; ticket?.cancel(); finish() }
    fun close() {
        if (closed) return
        closed = true
        folderObserver.close()
        cancelPending()
    }
}
