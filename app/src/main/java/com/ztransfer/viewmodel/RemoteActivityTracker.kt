package com.ztransfer.viewmodel

import androidx.annotation.MainThread
import java.io.Closeable

/**
 * Keep album work paused while either a monitor screen or its camera cleanup is alive.
 * A replacement screen/session can overlap the old session's non-cancellable teardown.
 * Acquire and release on Main, alongside the ViewModel's file-scan state.
 */
internal class RemoteActivityTracker(private val onActiveChanged: (Boolean) -> Unit) {
    private var owners = 0

    @MainThread
    fun acquire(): Closeable {
        if (owners++ == 0) onActiveChanged(true)
        var released = false
        return Closeable {
            if (!released) {
                released = true
                if (--owners == 0) onActiveChanged(false)
            }
        }
    }
}
