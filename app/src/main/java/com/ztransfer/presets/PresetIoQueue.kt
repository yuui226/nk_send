package com.ztransfer.presets

import android.os.CancellationSignal
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

internal typealias PresetIoTicket = SerialPresetQueue.Ticket<CancellationSignal>

/** Process-wide SAF worker; provider reads and permission cleanup remain off the UI thread. */
internal object PresetIoQueue {
    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    private val worker = SerialPresetQueue(
        scope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
        deliveryDispatcher = Dispatchers.Main.immediate,
        cancellationScope = CoroutineScope(SupervisorJob() + Dispatchers.IO.limitedParallelism(1)),
        createSignal = ::CancellationSignal,
        cancelSignal = CancellationSignal::cancel,
        onCallbackFailure = { Log.e("PresetIoQueue", "Preset callback failed", it) },
    )
    fun cleanup(action: () -> Unit) = worker.cleanup(action)
    fun <T> submit(action: suspend (CancellationSignal) -> T, discard: (Result<T>) -> Unit = {},
        deliver: (Result<T>) -> Unit): PresetIoTicket = worker.submit(action, discard, deliver)
}
