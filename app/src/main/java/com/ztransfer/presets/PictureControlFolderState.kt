package com.ztransfer.presets

import android.content.Context
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.ztransfer.R
import com.ztransfer.protocol.NikonPictureControlFile
import com.ztransfer.protocol.encodeClassicPictureControl
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

internal enum class PictureControlImportFailure { READ, INVALID, UNSUPPORTED, TIMEOUT }
internal class PictureControlImportException(val reason: PictureControlImportFailure, cause: Throwable? = null) :
    Exception(reason.name, cause)

/** Folder browsing never writes to the camera. Only an explicit preset selection can do that. */
@androidx.compose.runtime.Stable
internal class PictureControlFolderState(
    context: Context,
    private val scope: CoroutineScope,
    private val notice: (Int) -> Unit,
) {
    private val app = context.applicationContext
    private val preferences = PictureControlFolderPreferences(app)
    private val repository = PresetFolderRepository(app.contentResolver, ".np3") { uri ->
        retainSharedPresetFolderGrant(app, PresetFolderOwner.PICTURE_CONTROL, uri)
    }
    var folder by mutableStateOf(preferences.folder)
        private set
    var files by mutableStateOf<List<PresetFile>>(emptyList())
        private set
    var failure by mutableStateOf<PresetFolderFailure?>(null)
        private set
    var scanning by mutableStateOf(false)
        private set
    var hasSnapshot by mutableStateOf(false)
        private set
    private var generation = 0L
    private var ticket: PresetIoTicket? = null
    private var timeout: Job? = null
    private var closed = false
    fun refresh() { if (!scanning) folder?.let { scan(it, false) } }
    fun changeFolder(uri: Uri) { scan(uri, true) }

    private fun scan(uri: Uri, replacing: Boolean) {
        if (closed) return
        cancelScan()
        val id = generation
        scanning = true
        timeout = scope.launch {
            delay(10_000)
            if (!closed && generation == id) {
                cancelScan()
                if (!replacing) failure = PresetFolderFailure.READ
                notice(R.string.picture_control_read_timeout)
            }
        }
        ticket = PresetIoQueue.submit({ repository.scan(uri, replacing, it) },
            discard = { if (it.getOrNull()?.acquired == true) repository.releaseGrant(uri) }) { result ->
            if (closed || generation != id) return@submit
            timeout?.cancel(); timeout = null; ticket = null; scanning = false
            result.fold(onSuccess = { snapshot ->
                val previous = folder
                val owned = preferences.ownsGrant
                if (replacing) {
                    preferences.replace(uri, snapshot.acquired || (previous == uri && owned))
                    folder = uri
                    if (previous != null && previous != uri && owned) {
                        PresetIoQueue.cleanup { repository.releaseGrant(previous) }
                    }
                }
                files = snapshot.files
                failure = null
                hasSnapshot = true
            }, onFailure = { error ->
                val reason = (error as? PresetFolderException)?.reason ?: PresetFolderFailure.READ
                if (replacing) notice(presetFolderMessage(reason)) else failure = reason
            })
        }
    }

    /** Bounded provider reads use the same serial worker implementation as LUT. */
    suspend fun read(file: PresetFile): NikonPictureControlFile {
        val result = withTimeoutOrNull(10_000) {
            suspendCancellableCoroutine<Result<NikonPictureControlFile>> { continuation ->
                val request = PresetIoQueue.submit({ signal ->
                    val parsed = try {
                        app.contentResolver.openAssetFileDescriptor(file.uri, "r", signal)?.use { descriptor ->
                            descriptor.createInputStream().use { stream ->
                                NikonPictureControlFile.read(stream) { signal.throwIfCanceled() }
                            }
                        } ?: throw PictureControlImportException(PictureControlImportFailure.READ)
                    } catch (error: IllegalArgumentException) {
                        throw PictureControlImportException(PictureControlImportFailure.INVALID, error)
                    } catch (error: PictureControlImportException) {
                        throw error
                    } catch (error: Exception) {
                        throw PictureControlImportException(PictureControlImportFailure.READ, error)
                    }
                    // A .np3 suffix alone does not guarantee a format this camera writer understands.
                    try { parsed.encodeClassicPictureControl() }
                    catch (error: Exception) {
                        throw PictureControlImportException(PictureControlImportFailure.UNSUPPORTED, error)
                    }
                    parsed
                }) { if (continuation.isActive) continuation.resume(it) }
                continuation.invokeOnCancellation { request.cancel() }
            }
        } ?: throw PictureControlImportException(PictureControlImportFailure.TIMEOUT)
        return result.getOrElse { failure ->
            throw (failure as? PictureControlImportException
                ?: PictureControlImportException(PictureControlImportFailure.READ, failure))
        }
    }

    private fun cancelScan() {
        generation++
        ticket?.cancel(); ticket = null
        timeout?.cancel(); timeout = null
        scanning = false
    }
    fun close() { closed = true; cancelScan() }
}
