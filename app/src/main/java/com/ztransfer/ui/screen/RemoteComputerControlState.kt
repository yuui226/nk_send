package com.ztransfer.ui.screen

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Job
import kotlinx.coroutines.sync.Mutex

/** Actual session state is separate from the user's saved PC preference. */
@Stable
internal class RemoteComputerControlState {
    var enabled by mutableStateOf(false)
    var busy by mutableStateOf(false)
    var changeJob: Job? = null
    var recordingJob: Job? = null

    companion object {
        // Serialize entry/reconnect with the previous monitor's non-cancellable camera release.
        val sessionMutex = Mutex()
    }
}
