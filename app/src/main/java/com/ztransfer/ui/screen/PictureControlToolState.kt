package com.ztransfer.ui.screen

import android.content.ActivityNotFoundException
import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.layout.LayoutCoordinates
import com.ztransfer.BuildConfig
import com.ztransfer.R
import com.ztransfer.presets.PictureControlFolderState
import com.ztransfer.protocol.BuiltInPictureControl
import com.ztransfer.protocol.builtInPictureControls
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Keep feature state and generated Compose code out of the large monitor entry method. */
@Stable
internal class PictureControlToolState(val folders: PictureControlFolderState) {
    var panel by mutableStateOf(false)
    var closeRequested by mutableStateOf(false)
    var anchor by mutableStateOf<LayoutCoordinates?>(null)
    var report by mutableStateOf("")
    var loading by mutableStateOf(false)
    var presets by mutableStateOf<Result<List<BuiltInPictureControl>>?>(null)
        internal set
    var editingSlot by mutableStateOf<Int?>(null)
    var pickerActive by mutableStateOf(false)
        internal set
    internal var pickedFolder by mutableStateOf<Uri?>(null)
    internal var pickerTarget by mutableStateOf<Int?>(null)
    internal var pickerReturned by mutableStateOf(false)
    var chooseFolder: (Int) -> Unit = {}
        internal set

    companion object {
        // Save navigation only. Camera status, layouts and logs are reloaded on recreation.
        fun saver(folders: PictureControlFolderState) = listSaver<PictureControlToolState, Any>(
            save = { listOf(it.editingSlot ?: 0, it.pickerActive, it.pickedFolder?.toString().orEmpty(),
                it.pickerTarget ?: 0, it.pickerReturned) },
            restore = { saved -> PictureControlToolState(folders).apply {
                editingSlot = (saved[0] as Int).takeIf { it in 201..209 }
                pickerActive = saved[1] as Boolean
                pickedFolder = (saved[2] as String).takeIf(String::isNotEmpty)?.let(Uri::parse)
                pickerTarget = (saved[3] as Int).takeIf { it in 201..209 }
                pickerReturned = saved[4] as Boolean
            } },
        )
    }
}

@Composable
internal fun rememberPictureControlToolState(
    services: RemoteScreenServices, onNotice: (Int) -> Unit,
): PictureControlToolState {
    val notice by rememberUpdatedState(onNotice)
    val folders = remember(services.context, services.scope) {
        PictureControlFolderState(services.context, services.scope) { notice(it) }
    }
    DisposableEffect(folders) { onDispose { folders.close() } }
    val saver = remember(folders) { PictureControlToolState.saver(folders) }
    val state = rememberSaveable(folders, saver = saver) { PictureControlToolState(folders) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        state.pickedFolder = uri
        state.pickerActive = false
        state.pickerReturned = true
    }
    SideEffect {
        state.chooseFolder = { slot ->
            state.pickerTarget = slot
            state.pickerActive = true
            try { picker.launch(folders.folder) }
            catch (_: ActivityNotFoundException) {
                state.pickerActive = false
                state.pickerTarget = null
                notice(R.string.lut_folder_denied)
            } catch (_: SecurityException) {
                state.pickerActive = false
                state.pickerTarget = null
                notice(R.string.lut_folder_denied)
            }
        }
    }
    LaunchedEffect(state) {
        state.presets = withContext(Dispatchers.IO) {
            runCatching { builtInPictureControls(services.context.assets) }
        }
        if (!BuildConfig.DEBUG) return@LaunchedEffect
        val initialReport = state.report
        val saved = withContext(Dispatchers.IO) {
            runCatching { PictureControlReports.latest(services.context.filesDir) }.getOrNull()
                ?: services.context.getSharedPreferences("remote_diagnostics", Context.MODE_PRIVATE)
                    .getString("picture_control_report_v1", null)
        }
        if (!saved.isNullOrBlank() && state.report == initialReport) state.report = saved
    }
    return state
}

/** Call after the monitor's close effects so a returned picker can reopen its original editor. */
@Composable
internal fun PictureControlFolderReturnEffect(state: PictureControlToolState, resumed: Boolean, visible: Boolean) {
    LaunchedEffect(state, resumed, state.pickerReturned) {
        if (resumed && state.pickerReturned) {
            val uri = state.pickedFolder
            state.pickedFolder = null
            state.pickerReturned = false
            if (uri != null) state.folders.changeFolder(uri)
            if (visible) {
                state.editingSlot = state.pickerTarget
                // The picker usually leaves the loaded panel mounted. Its opening effect
                // will not run again, so do not replace its settled loading state here.
                // A recreated/closed panel will read the camera and clear loading itself.
                if (!state.panel) state.loading = true
                state.panel = true
                state.closeRequested = false
            }
            state.pickerTarget = null
        }
    }
}
