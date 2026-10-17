package com.ztransfer.protocol

import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** Connection-owned mode accounting; concurrent stop/exit callers wait for the same cleanup. */
internal class RemoteMovieApplicationState {
    @Volatile var operationSet = false
    @Volatile var propertySet = false
    private val cleanupMutex = Mutex()

    suspend fun clear(
        allowed: () -> Boolean,
        clearOperation: suspend () -> Int,
        clearProperty: suspend () -> Int,
        log: (String) -> Unit = {},
        pause: suspend (Long) -> Unit = { delay(it) },
    ): Boolean = cleanupMutex.withLock {
        if (!allowed()) return@withLock false
        // Once a command is sent, finish receiving its response and updating the flags even
        // if the stop button's coroutine is cancelled by leaving the monitor.
        withContext(NonCancellable) {
            suspend fun release(label: String, command: suspend () -> Int): Boolean {
                var response = runCatching { command() }.getOrDefault(-1)
                repeat(2) {
                    if (response == Lab.DEVICE_BUSY) {
                        pause(200L)
                        response = runCatching { command() }.getOrDefault(-1)
                    }
                }
                if (response != Lab.OK) log("!! $label resp=0x%04X".format(response and 0xFFFF))
                return response == Lab.OK
            }
            if (operationSet && release("ChangeApplicationMode(0)", clearOperation)) operationSet = false
            if (propertySet && release("ApplicationMode=0", clearProperty)) propertySet = false
            !operationSet && !propertySet
        }
    }
}
