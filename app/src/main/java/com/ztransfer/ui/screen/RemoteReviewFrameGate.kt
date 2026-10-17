package com.ztransfer.ui.screen

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Pause between complete LV transactions; never cancel a packet halfway through its response. */
internal class RemoteReviewFrameGate {
    private val paused = MutableStateFlow(false)
    private val transaction = Mutex()

    fun pause() { paused.value = true }
    fun resume() { paused.value = false }
    suspend fun awaitIdle() { transaction.withLock { } }

    suspend fun <T> withFrame(block: suspend () -> T): T {
        while (true) {
            paused.first { !it }
            transaction.lock()
            try {
                if (!paused.value) return block()
            } finally {
                transaction.unlock()
            }
        }
    }
}
