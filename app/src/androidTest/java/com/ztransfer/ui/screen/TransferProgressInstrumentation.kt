package com.ztransfer.ui.screen

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import android.os.SystemClock
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationVector1D
import androidx.compose.runtime.AbstractApplier
import androidx.compose.runtime.BroadcastFrameClock
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.snapshots.Snapshot
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs

/** Real Compose effect lifetimes, driven by deterministic frames; no camera or preference writes. */
class TransferProgressInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val report = Bundle()
        var result = Activity.RESULT_CANCELED
        var composition: Composition? = null
        var recomposer: Recomposer? = null
        var scope: CoroutineScope? = null
        try {
            val clock = BroadcastFrameClock()
            val target = mutableStateOf(0.65f)
            val owner = mutableStateOf(1L)
            val visible = mutableStateOf(true)
            val unrelated = mutableStateOf(0)
            val actual = AtomicReference<Animatable<Float, AnimationVector1D>>()
            val reference = AtomicReference<Animatable<Float, AnimationVector1D>>()
            val compositions = AtomicInteger()
            val asyncFailure = AtomicReference<Throwable>()
            runOnMainSync {
                val hostScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate + clock +
                    CoroutineExceptionHandler { _, error -> asyncFailure.set(error) })
                scope = hostScope
                val hostRecomposer = Recomposer(hostScope.coroutineContext)
                recomposer = hostRecomposer
                hostScope.launch { hostRecomposer.runRecomposeAndApplyChanges() }
                composition = Composition(EmptyApplier(), hostRecomposer).apply {
                    setContent {
                        // Reading this forces an unrelated recomposition without changing targets.
                        unrelated.value
                        if (visible.value) {
                            val progress = rememberSmoothTransferProgress(target.value, owner.value)
                            val control = rememberSmoothTransferProgress(0.65f, "reference")
                            SideEffect {
                                actual.set(progress)
                                reference.set(control)
                                compositions.incrementAndGet()
                            }
                        }
                    }
                }
            }
            var frameNanos = 0L
            fun frame() {
                frameNanos += 16_666_667L
                runOnMainSync {
                    // This standalone composition has no Android View driving global snapshots.
                    Snapshot.sendApplyNotifications()
                    clock.sendFrame(frameNanos)
                }
                waitForIdleSync()
                asyncFailure.get()?.let { throw it }
            }
            fun read(animation: Animatable<Float, AnimationVector1D>): ProgressFrame {
                lateinit var value: ProgressFrame
                runOnMainSync {
                    value = ProgressFrame(animation.value, animation.velocity, animation.targetValue, animation.isRunning)
                }
                return value
            }
            fun await(message: String, condition: () -> Boolean) {
                val deadline = SystemClock.uptimeMillis() + 5_000
                while (SystemClock.uptimeMillis() < deadline) {
                    if (condition()) return
                    frame()
                }
                error(message)
            }
            fun assertMatchesUninterruptedReference() {
                val observed = read(actual.get())
                val expected = read(reference.get())
                check(abs(observed.value - expected.value) < 0.00002f &&
                    abs(observed.velocity - expected.velocity) < 0.00002f) {
                    "A duplicate/regressing sample restarted motion: actual=$observed reference=$expected"
                }
            }

            await("Initial progress spring did not start") {
                actual.get()?.let { read(it).value > 0.02f && read(it).velocity > 0.5f } == true
            }
            assertMatchesUninterruptedReference()
            val beforeFrames = compositions.get()
            repeat(3) { frame() }
            check(compositions.get() == beforeFrames) { "Progress frames recomposed their content" }

            // A stale sample must leave the original trajectory untouched, including its speed.
            runOnMainSync { target.value = 0.2f }
            repeat(3) { frame(); assertMatchesUninterruptedReference() }
            runOnMainSync { target.value = 0.65f; unrelated.value++ }
            repeat(2) { frame(); assertMatchesUninterruptedReference() }

            // At the first observation of the new target, the untouched control carries the
            // velocity the old trajectory had at cancellation. The new target must retain it.
            runOnMainSync { target.value = 0.95f }
            await("Forward target was not accepted") { read(actual.get()).target == 0.95f }
            val retargeted = read(actual.get())
            val continuing = read(reference.get())
            check(retargeted.velocity > 0.01f && abs(retargeted.velocity - continuing.velocity) < 0.00002f) {
                "Retargeting lost velocity: actual=$retargeted previous=$continuing"
            }

            var previous = retargeted.value
            listOf(0.96f, 0.97f, 0.98f, 0.99f, 1f).forEach { next ->
                runOnMainSync { target.value = next }
                repeat(2) {
                    frame()
                    val current = read(actual.get()).value
                    check(current >= previous && current <= 1f) { "Progress regressed or overshot: $previous -> $current" }
                    previous = current
                }
            }
            await("Rapid samples never completed") {
                val current = read(actual.get())
                check(current.value >= previous && current.value <= 1f) { "Completion regressed or overshot" }
                previous = current.value
                current.value == 1f && !current.running
            }

            // A new owner starts independently; replacing an owner mid-spring cancels its work.
            val completed = actual.get()
            runOnMainSync { owner.value = 2L; target.value = 0.8f }
            await("New owner reused its predecessor") { actual.get() !== completed }
            check(read(actual.get()).let { it.value == 0f && it.velocity == 0f }) {
                "New owner inherited progress or velocity"
            }
            await("Second owner did not animate") { read(actual.get()).value > 0.02f }
            val replaced = actual.get()
            runOnMainSync { owner.value = 3L; target.value = 0.25f }
            await("Running owner was not replaced") { actual.get() !== replaced }
            check(!read(replaced).running && read(actual.get()).value == 0f) {
                "Owner change retained an old animation or failed to reset"
            }

            await("Final owner did not animate") { read(actual.get()).value > 0.005f }
            val removed = actual.get()
            runOnMainSync { visible.value = false }
            await("Leaving composition retained its animation") { !read(removed).running }
            val stopped = read(removed)
            repeat(8) { frame() }
            check(read(removed) == stopped) { "Removed progress kept advancing" }

            report.putString("stream", "PASS progress velocity continuity, stale/duplicate samples, frame-only drawing, rapid completion, owner reset and disposal cancellation\n")
            result = Activity.RESULT_OK
        } catch (error: Throwable) {
            report.putString("stream", error.stackTraceToString())
        } finally {
            runOnMainSync {
                composition?.dispose()
                recomposer?.cancel()
                scope?.cancel()
            }
            finish(result, report)
        }
    }

    private data class ProgressFrame(val value: Float, val velocity: Float, val target: Float, val running: Boolean)

    private class EmptyApplier : AbstractApplier<Unit>(Unit) {
        override fun insertTopDown(index: Int, instance: Unit) = Unit
        override fun insertBottomUp(index: Int, instance: Unit) = Unit
        override fun remove(index: Int, count: Int) = Unit
        override fun move(from: Int, to: Int, count: Int) = Unit
        override fun onClear() = Unit
    }
}
