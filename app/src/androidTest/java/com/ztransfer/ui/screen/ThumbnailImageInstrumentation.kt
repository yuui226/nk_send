package com.ztransfer.ui.screen

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.graphics.Bitmap
import android.os.Bundle
import android.os.SystemClock
import androidx.activity.compose.setContent
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp
import com.ztransfer.MainActivity
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableSharedFlow
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** Real Compose lifetimes for image fades and canceled cell reads; no camera or preferences. */
class ThumbnailImageInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val report = Bundle()
        var activity: MainActivity? = null
        var result = Activity.RESULT_CANCELED
        try {
            val monitor = addMonitor(MainActivity::class.java.name, null, false)
            targetContext.startActivity(Intent(targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            activity = checkNotNull(waitForMonitorWithTimeout(monitor, 10_000)) as MainActivity
            removeMonitor(monitor)
            val host = checkNotNull(activity)
            val image = Bitmap.createBitmap(24, 24, Bitmap.Config.RGB_565).asImageBitmap()
            val handle = mutableStateOf(1)
            val enabled = mutableStateOf(true)
            val allowRemote = mutableStateOf(true)
            val busy = mutableStateOf(false)
            val visible = mutableStateOf(true)
            val hasItems = mutableStateOf(false)
            val entryOpacity = AtomicReference<State<Float>>()
            val sawEntryFrame = AtomicBoolean()
            val cache = mutableMapOf<Int, ImageBitmap>(1 to image)
            val gate = AtomicReference(CompletableDeferred<ImageBitmap?>())
            val pending = AtomicReference<ThumbnailImagePresentation>()
            val calls = AtomicInteger()
            val cancellations = AtomicInteger()
            val compositions = AtomicInteger()
            val sawFadeStart = AtomicBoolean()
            val calledRemote = AtomicReference<Boolean>()
            val thumbnailReadyEvents = MutableSharedFlow<Int>(extraBufferCapacity = 8)
            runOnMainSync {
                host.setContent {
                    val entry = rememberThumbnailBatchEntrance(hasItems.value)
                    if (visible.value) {
                        val presentation = rememberThumbnailImagePresentation(
                            handle = handle.value,
                            transfersBusy = busy.value,
                            loadEnabled = enabled.value,
                            allowRemote = allowRemote.value,
                            cachedThumbnail = { cache[handle.value] },
                            loadThumbnail = { remote ->
                                calls.incrementAndGet()
                                calledRemote.set(remote)
                                try { gate.get().await() }
                                finally {
                                    if (!kotlin.coroutines.coroutineContext[kotlinx.coroutines.Job]!!.isActive) {
                                        cancellations.incrementAndGet()
                                    }
                                }
                            },
                            thumbnailReadyEvents = thumbnailReadyEvents,
                        )
                        SideEffect {
                            entryOpacity.set(entry)
                            pending.set(presentation)
                            compositions.incrementAndGet()
                            if (presentation.image.value != null && presentation.alpha.value == 0f) {
                                sawFadeStart.set(true)
                            }
                        }
                        Box(Modifier.size(96.dp)) {
                            // Observe the same threshold and draw-phase state as both grid renderers.
                            if (presentation.showPlaceholder.value) Box(Modifier.size(24.dp))
                            presentation.image.value?.let {
                                Image(it, null, Modifier.size(96.dp).graphicsLayer {
                                    val entrance = entry.value
                                    if (entrance > 0f && entrance < 1f) sawEntryFrame.set(true)
                                    alpha = presentation.alpha.value * entrance
                                })
                            }
                        }
                    }
                }
            }
            fun await(message: String, condition: () -> Boolean) {
                val deadline = SystemClock.uptimeMillis() + 5_000
                while (SystemClock.uptimeMillis() < deadline) {
                    var ready = false
                    runOnMainSync { ready = condition() }
                    if (ready) return
                    SystemClock.sleep(20)
                }
                error(message)
            }
            await("Cached image flashed a placeholder") {
                pending.get()?.let { it.image.value === image && it.alpha.value == 1f && !it.showPlaceholder.value } == true
            }
            check(calls.get() == 0) { "Cache hit started another load" }
            check(entryOpacity.get().value == 0f) { "Entrance ran before the first batch existed" }
            val beforeEntry = compositions.get()
            runOnMainSync { hasItems.value = true }
            await("First cached batch did not finish its entrance") { entryOpacity.get().value == 1f }
            check(sawEntryFrame.get()) { "Batch jumped directly to opaque without a fade frame" }
            check(compositions.get() - beforeEntry <= 2) { "Batch opacity recomposed the cells every frame" }
            runOnMainSync { hasItems.value = false }
            waitForIdleSync()
            runOnMainSync { hasItems.value = true }
            waitForIdleSync()
            check(entryOpacity.get().value == 1f && calls.get() == 0) {
                "An empty/filter batch replayed the entrance or reloaded cached images"
            }

            // Reused slots have independent image/opacity state, and local-only reads are preserved.
            runOnMainSync { handle.value = 2; allowRemote.value = false }
            await("New cell did not request its local thumbnail") {
                calls.get() == 1 && calledRemote.get() == false && pending.get().image.value == null
            }
            val beforeFade = compositions.get()
            runOnMainSync { gate.get().complete(image) }
            await("Fresh image fade did not finish") {
                pending.get().image.value === image && pending.get().alpha.value == 1f && !pending.get().showPlaceholder.value
            }
            check(sawFadeStart.get()) { "Fresh image bypassed its fade" }
            check(compositions.get() - beforeFade <= 4) { "Image opacity caused per-frame recomposition" }
            runOnMainSync { busy.value = true; allowRemote.value = true; enabled.value = false }
            waitForIdleSync()
            check(calls.get() == 1 && pending.get().alpha.value == 1f) { "Loaded cell restarted or disappeared" }

            // A date beginning to collapse must cancel unfinished reads, then resume on expansion.
            runOnMainSync { gate.set(CompletableDeferred()); handle.value = 3 }
            waitForIdleSync()
            check(calls.get() == 1) { "Collapsed cell started a load" }
            runOnMainSync { enabled.value = true }
            await("Expanded cell did not resume") { calls.get() == 2 }
            runOnMainSync { enabled.value = false }
            await("Collapsing date retained a pending read") { cancellations.get() == 1 }
            runOnMainSync { enabled.value = true }
            await("Canceled cell could not load on expansion") { calls.get() == 3 }

            // Leaving the cell invalidates its pending result; a cached replacement remains intact.
            val oldGate = gate.get()
            runOnMainSync { cache[4] = image; handle.value = 4 }
            await("Reused cell retained the previous read") {
                cancellations.get() == 2 && pending.get().image.value === image && pending.get().alpha.value == 1f
            }
            runOnMainSync { oldGate.complete(null); visible.value = false }
            waitForIdleSync()
            runOnMainSync { visible.value = true }
            await("Remounted cached cell replayed its fade") {
                pending.get().image.value === image && pending.get().alpha.value == 1f && !pending.get().showPlaceholder.value
            }
            check(calls.get() == 3) { "Cached remount restarted a load" }

            // A local miss during FHD preview retries once remote reads resume; transfer transitions
            // may restart an unfinished read, but must not clear an image that already completed.
            runOnMainSync {
                gate.set(CompletableDeferred<ImageBitmap?>().apply { complete(null) })
                handle.value = 5
                allowRemote.value = false
            }
            await("Local cache miss was not attempted") { calls.get() == 4 && calledRemote.get() == false }
            runOnMainSync { gate.set(CompletableDeferred()); allowRemote.value = true }
            await("Closing preview did not restore remote reads") { calls.get() == 5 && calledRemote.get() == true }
            runOnMainSync { busy.value = !busy.value }
            await("Transfer transition did not restart the pending read") { calls.get() == 6 && cancellations.get() == 3 }
            runOnMainSync { gate.get().complete(image) }
            await("Retried thumbnail never appeared") { pending.get().image.value === image && pending.get().alpha.value == 1f }
            // New JPGs may initially have no thumbnail. A later background disk write must
            // fill the existing cell without scrolling, polling, or another camera request.
            runOnMainSync {
                gate.set(CompletableDeferred<ImageBitmap?>().apply { complete(null) })
                handle.value = 6
            }
            await("New capture did not make its first request") { calls.get() == 7 }
            runOnMainSync {
                gate.set(CompletableDeferred<ImageBitmap?>().apply { complete(image) })
                check(thumbnailReadyEvents.tryEmit(99))
            }
            SystemClock.sleep(100)
            check(calls.get() == 7) { "Another photo's cache update reloaded this cell" }
            runOnMainSync { check(thumbnailReadyEvents.tryEmit(6)) }
            await("Background thumbnail did not fill the existing cell") {
                calls.get() == 8 && calledRemote.get() == false &&
                    pending.get().image.value === image && pending.get().alpha.value == 1f
            }
            runOnMainSync { check(thumbnailReadyEvents.tryEmit(6)) }
            SystemClock.sleep(100)
            check(calls.get() == 8) { "Ready image kept observing cache writes" }
            report.putString("stream", "PASS thumbnail cache, fade, preview/transfer retries, collapse cancellation, cell reuse, remount and late background readiness\n")
            result = Activity.RESULT_OK
        } catch (error: Throwable) {
            report.putString("stream", error.stackTraceToString())
        } finally {
            runOnMainSync { activity?.finish() }
            finish(result, report)
        }
    }
}
