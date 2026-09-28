package com.ztransfer.lut

import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.ztransfer.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

internal data class LutLayer(val request: Long, val file: LutFile, val table: CubeLut, val retry: Int = 0)

/** Main-thread coordinator. Only a presented GPU frame may commit a selection or disable false color. */
@androidx.compose.runtime.Stable
internal class LutMonitorState(
    private val repository: LutSource,
    private val preferences: LutPreferences,
    private val scope: CoroutineScope,
    private val closeFalseColor: () -> Unit,
    private val notice: (Int) -> Unit,
) {
    var folder by mutableStateOf(preferences.folder)
        private set
    var files by mutableStateOf<List<LutFile>>(emptyList())
        private set
    var folderFailure by mutableStateOf<LutFolderFailure?>(null)
        private set
    var scanning by mutableStateOf(false)
        private set
    var loading by mutableStateOf<Uri?>(null)
        private set
    var active by mutableStateOf<LutLayer?>(null)
        private set
    var candidate by mutableStateOf<LutLayer?>(null)
        private set
    var menuOpen by mutableStateOf(false)
        private set
    var closeMenuRequested by mutableStateOf(false)
        private set
    private var generation = 0L
    private var ticket: LutIoQueue.Ticket? = null
    private var timeout: Job? = null
    private var movie: Boolean? = null
    private var available = false
    private var disposed = false
    private var manualRequest = false
    private var gpuRetryUsed = false
    private val suppressedSelections = mutableMapOf<Boolean, Uri>()

    fun environment(movie: Boolean, available: Boolean, visible: Boolean) {
        val changed = this.movie != movie || this.available != available
        this.movie = movie
        this.available = available
        if (!visible) { off(); return }
        if (!changed) return
        invalidate()
        active = null
        if (!available) return
        preferences.selection(movie)?.takeUnless { it == suppressedSelections[movie] }?.let { uri ->
            val file = files.find { it.uri == uri } ?: LutFile(uri, uri.lastPathSegment.orEmpty() + ".cube", null, null)
            select(file, manual = false)
        }
    }

    fun openMenu() {
        menuOpen = true
        closeMenuRequested = false
        folder?.let { scan(it, replacing = false) }
    }
    fun dismissMenu() {
        menuOpen = false
        closeMenuRequested = false
        if (manualRequest) invalidate()
    }
    fun off() {
        invalidate()
        active = null
        movie?.let { preferences.select(it, null) }
    }
    fun prepareFolderPicker() { invalidate() }
    fun chooseOff() { off(); closeMenuRequested = true }
    fun falseColorEnabled() { off() }

    fun select(file: LutFile, manual: Boolean = true) {
        if (!available) { notice(R.string.lut_frame_unavailable); return }
        if (manual) movie?.let { suppressedSelections.remove(it) }
        val id = begin(manual)
        loading = file.uri
        ticket = LutIoQueue.submit({ repository.read(file, it) }) { result ->
            if (!valid(id)) return@submit
            result.fold(
                onSuccess = { candidate = LutLayer(id, file, it) },
                onFailure = { failLoad(it) },
            )
        }
    }

    /** TextureView has consumed the candidate frame, not merely finished uploading the table. */
    fun presented(id: Long) {
        val next = candidate?.takeIf { it.request == id && valid(id) } ?: return
        active = next
        candidate = null
        loading = null
        timeout?.cancel(); timeout = null
        ticket = null
        preferences.select(movie ?: return, next.file.uri)
        closeFalseColor()
        if (manualRequest) closeMenuRequested = true
        manualRequest = false
    }

    fun renderFailed(layer: LutLayer, cause: Throwable) {
        if (candidate !== layer && active !== layer) return
        android.util.Log.w("MonitorLut", "Rendering failed for request ${layer.request}", cause)
        val unsupportedInput = (cause as? LutException)?.reason == LutFailure.INPUT_COLOR
        if (!gpuRetryUsed && !unsupportedInput) {
            gpuRetryUsed = true
            if (candidate === layer) candidate = layer.copy(retry = layer.retry + 1)
            else active = layer.copy(retry = layer.retry + 1)
            return
        }
        movie?.let { suppressedSelections[it] = layer.file.uri }
        if (candidate === layer) failLoad(if (unsupportedInput) cause else LutException(LutFailure.GPU, "Renderer failed"))
        else {
            invalidate()
            active = null
            // Keep the saved choice for explicit retry, but do not automatically retry this page.
            notice(if (unsupportedInput) R.string.lut_input_color_unsupported else R.string.lut_gpu_failed)
        }
    }

    fun changeFolder(uri: Uri) {
        if (disposed) return
        menuOpen = true
        closeMenuRequested = false
        scan(uri, replacing = true)
    }

    private fun scan(uri: Uri, replacing: Boolean) {
        val id = begin(false) {
            if (!replacing) folderFailure = LutFolderFailure.READ
            notice(R.string.lut_read_timeout)
        }
        scanning = true
        ticket = LutIoQueue.submit({ signal -> repository.scan(uri, replacing, signal) },
            discard = { result -> if (result.getOrNull()?.acquired == true) repository.releaseGrant(uri) }) { result ->
            if (!valid(id)) return@submit
            scanning = false
            timeout?.cancel(); timeout = null
            ticket = null
            result.fold(onSuccess = { scan ->
                val list = scan.files
                folderFailure = null
                files = list
                if (replacing && uri == folder && scan.acquired) preferences.markFolderGrantOwned()
                if (replacing && uri != folder) {
                    val previous = folder
                    val ownedPrevious = preferences.ownsFolderGrant
                    preferences.replaceFolder(uri, scan.acquired || (previous == uri && ownedPrevious))
                    folder = uri
                    active = null
                    suppressedSelections.clear()
                    if (previous != null && previous != uri && ownedPrevious) {
                        LutIoQueue.cleanup { repository.releaseGrant(previous) }
                    }
                } else {
                    for (mode in listOf(false, true)) {
                        val selection = preferences.selection(mode)
                        if (selection != null && list.none { it.uri == selection }) {
                            preferences.select(mode, null)
                            if (mode == movie) {
                                active = null
                                notice(R.string.lut_file_missing)
                            }
                        }
                    }
                    if (active == null && available) {
                        movie?.let { mode ->
                            val uri = preferences.selection(mode)
                            if (uri != null && uri != suppressedSelections[mode]) {
                                list.find { it.uri == uri }?.let { select(it, manual = false) }
                            }
                        }
                    }
                    active?.let { current ->
                        list.find { it.uri == current.file.uri }?.let { updated ->
                            if ((updated.modified != null && updated.modified != current.file.modified) ||
                                (updated.size != null && updated.size != current.file.size)) select(updated, manual = false)
                        }
                    }
                }
            }, onFailure = { failure ->
                val reason = when (failure) {
                    is LutFolderException -> failure.reason
                    is SecurityException -> LutFolderFailure.DENIED
                    else -> LutFolderFailure.READ
                }
                if (replacing) {
                    notice(folderMessage(reason))
                } else {
                    folderFailure = reason
                    if (reason == LutFolderFailure.MISSING || reason == LutFolderFailure.DENIED) {
                        active = null
                        preferences.clearSelections()
                    }
                }
            })
        }
    }

    private fun begin(manual: Boolean, onTimeout: () -> Unit = { notice(R.string.lut_read_timeout) }): Long {
        invalidate()
        manualRequest = manual
        val id = generation
        timeout = scope.launch {
            delay(10_000)
            if (valid(id)) {
                invalidate()
                onTimeout()
            }
        }
        return id
    }
    private fun failLoad(failure: Throwable) {
        invalidate()
        notice(when ((failure as? LutException)?.reason) {
            LutFailure.INVALID -> R.string.lut_invalid
            LutFailure.UNSUPPORTED -> R.string.lut_unsupported
            LutFailure.TOO_LARGE -> R.string.lut_too_large
            LutFailure.GPU -> R.string.lut_gpu_failed
            LutFailure.INPUT_COLOR -> R.string.lut_input_color_unsupported
            else -> R.string.lut_read_failed
        })
    }
    private fun valid(id: Long) = !disposed && generation == id
    private fun invalidate() {
        generation++
        ticket?.cancel(); ticket = null
        timeout?.cancel(); timeout = null
        loading = null; candidate = null; scanning = false; manualRequest = false
    }
    fun suspendRendering() { available = false; invalidate(); active = null }
    fun close() { disposed = true; invalidate(); active = null }
}

internal fun folderMessage(reason: LutFolderFailure) = when (reason) {
    LutFolderFailure.MISSING -> R.string.lut_folder_missing
    LutFolderFailure.DENIED -> R.string.lut_folder_denied
    LutFolderFailure.READ -> R.string.lut_folder_read_failed
    LutFolderFailure.TOO_MANY -> R.string.lut_folder_too_many
}
