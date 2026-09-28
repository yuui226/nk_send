package com.ztransfer.lut

import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.os.CancellationSignal
import android.os.SystemClock
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Exercises the production coordinator with deliberately late provider results, without camera/UI. */
class LutStateInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }
    override fun onStart() {
        val report = Bundle()
        val raw = targetContext.getSharedPreferences("lut_state_test", Context.MODE_PRIVATE)
        raw.edit().clear().commit()
        val preferences = LutPreferences(raw)
        val source = FakeSource()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        var state: LutMonitorState? = null
        try {
            val notices = mutableListOf<Int>()
            var falseColorClosed = 0
            val tree = Uri.parse("content://lut-test/tree/folder")
            val a = LutFile(Uri.parse("content://lut-test/document/a"), "A.cube", 100, 1)
            val b = LutFile(Uri.parse("content://lut-test/document/b"), "B.cube", 100, 1)
            source.files = listOf(a, b)
            preferences.replaceFolder(tree, false)
            val controller = main {
                LutMonitorState(source, preferences, scope, { falseColorClosed++ }, { notices += it })
                    .also { state = it; it.environment(false, true, true) }
            }
            fun ready(file: LutFile) {
                val pending = source.nextRead()
                check(pending.file.uri == file.uri)
                pending.result.complete(Result.success(table()))
                await { controller.candidate != null }
            }
            fun present() = main { controller.presented(checkNotNull(controller.candidate).request) }

            main { controller.openMenu() }
            await { !controller.scanning }
            main { controller.select(a) }
            ready(a)
            main { check(preferences.selection(false) == null && falseColorClosed == 0) }
            present()
            main { check(controller.active?.file == a && preferences.selection(false) == a.uri && falseColorClosed == 1) }

            // Re-selecting the already presented LUT closes without reading or GPU replacement.
            val committed = main { checkNotNull(controller.active) }
            main { controller.select(a) }
            drain()
            main {
                check(controller.active === committed && controller.candidate == null)
                check(controller.closeMenuRequested && controller.loading == null)
            }
            check(source.reads.tryReceive().isFailure)

            main { controller.select(b) }
            val stale = source.nextRead()
            main { controller.falseColorEnabled() }
            stale.result.complete(Result.success(table()))
            drain()
            main { check(controller.active == null && controller.candidate == null && preferences.selection(false) == null) }

            // Restore only after a frame-ready session. Loading failure must retain the current LUT.
            main { preferences.select(false, a.uri); controller.environment(false, false, true); controller.environment(false, true, true) }
            ready(a); present()
            main { controller.select(b) }
            source.nextRead().result.complete(Result.failure(LutException(LutFailure.INVALID, "test")))
            await { controller.loading == null }
            main { check(controller.active?.file?.uri == a.uri && preferences.selection(false) == a.uri && notices.isNotEmpty()) }

            main { controller.openMenu() }
            await { !controller.scanning }
            main { controller.select(b) }
            val dismissed = source.nextRead()
            main { controller.dismissMenu() }
            dismissed.result.complete(Result.success(table()))
            drain()
            main { check(controller.active?.file?.uri == a.uri && controller.candidate == null) }

            main { preferences.select(true, b.uri); controller.environment(true, true, true) }
            ready(b); present()
            main {
                check(preferences.selection(false) == a.uri && preferences.selection(true) == b.uri)
                controller.environment(true, true, false)
                check(controller.active == null && preferences.selection(true) == null && preferences.selection(false) == a.uri)
                controller.environment(false, true, true)
            }
            ready(a); present()

            // A generic scan error is not evidence that files were removed.
            source.scanError = LutFolderException(LutFolderFailure.READ)
            main { controller.openMenu() }
            await { !controller.scanning }
            main { check(controller.active?.file?.uri == a.uri && preferences.selection(false) == a.uri) }
            source.scanError = null

            // Surface failure gets one automatic retry; later failure preserves choice, suppresses restore.
            main {
                controller.renderFailed(checkNotNull(controller.active), IllegalStateException())
                check(controller.active?.retry == 1)
                controller.renderFailed(checkNotNull(controller.active), IllegalStateException())
                check(controller.active == null && preferences.selection(false) == a.uri)
                controller.environment(false, false, true)
                controller.environment(false, true, true)
                check(controller.loading == null)
            }
            drain()
            main { controller.changeFolder(Uri.parse("content://lut-test/tree/new")) }
            await { !controller.scanning }
            main { check(controller.active == null && preferences.selection(false) == null && preferences.selection(true) == null) }
            report.putString("result", "PASS: presented-only commit, mutual exclusion, stale results, dismiss, mode, hide, scan failure, bounded GPU retry, folder reset")
            finish(Activity.RESULT_OK, report)
        } catch (failure: Throwable) {
            report.putString("failure", failure.stackTraceToString())
            finish(Activity.RESULT_CANCELED, report)
        } finally {
            main { state?.close(); scope.cancel() }
            raw.edit().clear().commit()
        }
    }

    private fun <T> main(block: () -> T): T {
        var value: Result<T>? = null
        runOnMainSync { value = runCatching(block) }
        return checkNotNull(value).getOrThrow()
    }
    private fun await(condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 4000
        while (!main(condition)) {
            check(SystemClock.uptimeMillis() < deadline) { "State did not settle" }
            SystemClock.sleep(10)
        }
    }
    private fun drain() {
        val done = CountDownLatch(1)
        main { LutIoQueue.submit({ Unit }) { done.countDown() } }
        check(done.await(4, TimeUnit.SECONDS)) { "IO queue did not settle" }
    }
    private fun table() = CubeLutParser.parse(("LUT_3D_SIZE 2\n" +
        "0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n").byteInputStream())

    private class FakeSource : LutSource {
        data class Read(val file: LutFile, val result: CompletableDeferred<Result<CubeLut>> = CompletableDeferred())
        val reads = Channel<Read>(Channel.UNLIMITED)
        @Volatile var files = emptyList<LutFile>()
        @Volatile var scanError: Exception? = null
        override suspend fun scan(tree: Uri, replacing: Boolean, signal: CancellationSignal): LutFolderSnapshot {
            scanError?.let { throw it }
            return LutFolderSnapshot(files, false)
        }
        override suspend fun read(file: LutFile, signal: CancellationSignal): CubeLut {
            val next = Read(file)
            reads.send(next)
            return next.result.await().getOrThrow() // Intentionally ignores cancellation, like a slow provider.
        }
        override fun releaseGrant(uri: Uri) = Unit
        fun nextRead() = runBlocking { withTimeout(4000) { reads.receive() } }
    }
}
