package com.ztransfer.ui.screen

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import com.ztransfer.MainActivity
import com.ztransfer.protocol.NikonCamera
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** Exercises real frame boundaries and conflated camera updates, without a connected camera. */
class PhotoCatalogInstrumentation : Instrumentation() {
    private data class Published(
        val caseId: Int,
        val handles: List<Int>,
        val motionActive: Boolean,
        val affectedDates: Set<String>,
    )
    private data class FrameBaseline(val caseId: Int, val ready: Boolean, val serial: Int)

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
            val caseId = mutableStateOf(0)
            val files = mutableStateOf(emptyList<NikonCamera.FileInfo>())
            val ready = mutableStateOf(false)
            val observed = AtomicReference<Published>()
            val history = CopyOnWriteArrayList<Published>()
            val baselineSerial = AtomicInteger()
            val frameBaseline = AtomicReference<FrameBaseline>()
            // Runs on the composition's side-effect phase to interrupt the exact preparation frame;
            // wall-clock polling could otherwise miss that brief state on a fast device.
            val intercept = AtomicReference<((Published) -> Unit)?>(null)
            runOnMainSync {
                host.setContent {
                    key(caseId.value) {
                        val composedCaseId = caseId.value
                        val composedReady = ready.value
                        val presentation = rememberPhotoCatalogPresentation(files.value, composedReady)
                        LaunchedEffect(composedCaseId, composedReady) {
                            val serial = baselineSerial.incrementAndGet()
                            repeat(3) { withFrameNanos { } }
                            frameBaseline.set(FrameBaseline(composedCaseId, composedReady, serial))
                        }
                        val snapshot = Published(
                            caseId = caseId.value,
                            handles = presentation.files.map { it.handle },
                            motionActive = presentation.motionActive,
                            affectedDates = presentation.affectedDates.toSet(),
                        )
                        SideEffect {
                            observed.set(snapshot)
                            history.add(snapshot)
                            intercept.get()?.invoke(snapshot)
                        }
                        Box(Modifier.fillMaxSize())
                    }
                }
            }
            fun file(handle: Int, date: String = "20261028") = NikonCamera.FileInfo(
                handle = handle,
                size = 1_000L,
                fileName = "DSC_${handle.toString().padStart(4, '0')}.JPG",
                captureDate = "${date}T120000",
            )
            fun await(message: String, predicate: (Published) -> Boolean) {
                val deadline = SystemClock.uptimeMillis() + 5_000
                while (SystemClock.uptimeMillis() < deadline) {
                    observed.get()?.let { if (predicate(it)) return }
                    SystemClock.sleep(10)
                }
                error("$message; last=${observed.get()}")
            }
            fun awaitBaseline(id: Int, catalogReady: Boolean, afterSerial: Int) {
                await("Case $id ready=$catalogReady did not cross its Compose frame barrier") {
                    it.caseId == id && frameBaseline.get()?.let { baseline ->
                        baseline.caseId == id && baseline.ready == catalogReady && baseline.serial > afterSerial
                    } == true
                }
            }
            fun startCase(id: Int, initial: List<NikonCamera.FileInfo>, catalogReady: Boolean) {
                intercept.set(null)
                val previousBaseline = frameBaseline.get()?.serial ?: 0
                runOnMainSync {
                    caseId.value = id
                    files.value = initial
                    ready.value = catalogReady
                }
                await("Case $id did not mount its initial catalog") {
                    it.caseId == id && it.handles == initial.map { f -> f.handle } &&
                        !it.motionActive && it.affectedDates.isEmpty()
                }
                // Android's main queue can be idle while a Compose frame is still pending. Require
                // a fresh barrier token, rather than letting the first live photo join the baseline.
                awaitBaseline(id, catalogReady, previousBaseline)
            }
            fun settled(id: Int, expected: List<NikonCamera.FileInfo>) {
                await("Case $id did not settle on the latest catalog") {
                    it.caseId == id && it.handles == expected.map { f -> f.handle } &&
                        !it.motionActive && it.affectedDates.isEmpty()
                }
            }

            // Scanning may publish partial catalogs; neither these nor initial scan completion animate.
            startCase(1, emptyList(), catalogReady = false)
            runOnMainSync { files.value = listOf(file(1)) }
            settled(1, listOf(file(1)))
            runOnMainSync { files.value = listOf(file(1), file(2)); ready.value = true }
            settled(1, listOf(file(1), file(2)))
            check(history.none { it.caseId == 1 && it.motionActive }) { "Initial scan animated as a live camera change" }

            // Once an empty catalog is ready, its first photo and the final deletion both animate.
            startCase(2, emptyList(), catalogReady = true)
            runOnMainSync { files.value = listOf(file(3)) }
            await("First photo in a ready empty catalog did not animate") {
                it.caseId == 2 && it.handles == listOf(3) && it.motionActive && "20261028" in it.affectedDates
            }
            runOnMainSync { files.value = emptyList() }
            await("Deleting the final photo lost its exit window") {
                it.caseId == 2 && it.handles.isEmpty() && it.motionActive && "20261028" in it.affectedDates
            }
            settled(2, emptyList())

            // Updates arrive faster than two display frames. A collectLatest-style preparation loop
            // would continually restart and publish nothing until this stream stopped.
            startCase(3, listOf(file(1)), catalogReady = true)
            for (count in 2..80) {
                runOnMainSync { files.value = (1..count).map { file(it) } }
                SystemClock.sleep(5)
            }
            check(history.any { it.caseId == 3 && it.handles.size in 2..79 }) {
                "Continuous camera updates starved catalog publication"
            }
            settled(3, (1..80).map { file(it) })

            // Withdraw B during the preparation frame, before it can replace A. The canceled visual
            // change must not leave animation flags or affected dates latched indefinitely.
            val original = listOf(file(101, "20261027"))
            val changed = listOf(file(102))
            startCase(4, original, catalogReady = true)
            val withdrew = AtomicBoolean()
            intercept.set { snapshot ->
                if (snapshot.caseId == 4 && snapshot.motionActive && snapshot.handles == listOf(101) &&
                    withdrew.compareAndSet(false, true)) files.value = original
            }
            runOnMainSync { files.value = changed }
            await("A → B preparation was not observed") { it.caseId == 4 && withdrew.get() }
            settled(4, original)
            intercept.set(null)

            // A rescan starts while a prior live update is waiting for its animation frame. Publishing
            // the scan's catalog must win permanently over the obsolete pending snapshot.
            startCase(5, original, catalogReady = true)
            val scanned = listOf(file(201, "20261026"), file(202, "20261026"))
            val interrupted = AtomicBoolean()
            intercept.set { snapshot ->
                if (snapshot.caseId == 5 && snapshot.motionActive && interrupted.compareAndSet(false, true)) {
                    ready.value = false
                    files.value = scanned
                }
            }
            runOnMainSync { files.value = changed }
            await("Rescan did not interrupt pending presentation") { it.caseId == 5 && interrupted.get() }
            settled(5, scanned)
            intercept.set(null)
            val afterScan = history.size
            SystemClock.sleep(400)
            check(history.drop(afterScan).all {
                it.caseId == 5 && it.handles == listOf(201, 202) && !it.motionActive && it.affectedDates.isEmpty()
            }) { "An obsolete presentation returned after rescan" }
            val previousBaseline = frameBaseline.get()?.serial ?: 0
            runOnMainSync { ready.value = true }
            awaitBaseline(5, catalogReady = true, afterSerial = previousBaseline)
            val resumed = scanned + file(203, "20261026")
            runOnMainSync { files.value = resumed }
            await("Presentation did not resume after rescan") {
                it.caseId == 5 && it.handles == listOf(201, 202, 203) && it.motionActive
            }
            settled(5, resumed)

            report.putString("stream", "PASS catalog scan, first/last photo, continuous updates, withdrawal and rescan interruption\n")
            result = Activity.RESULT_OK
        } catch (error: Throwable) {
            report.putString("stream", error.stackTraceToString())
        } finally {
            runOnMainSync { activity?.finish() }
            finish(result, report)
        }
    }
}
