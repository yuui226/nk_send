package com.ztransfer.filter

import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.os.Bundle
import android.os.CancellationSignal
import android.os.SystemClock
import android.provider.DocumentsContract
import com.ztransfer.R
import com.ztransfer.presets.PresetFile
import com.ztransfer.presets.PresetFolderException
import com.ztransfer.presets.PresetFolderFailure
import com.ztransfer.presets.PresetFolderSnapshot
import com.ztransfer.presets.PresetIoQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout

/** Production draft + serial queue, using real Android URI/cancellation with delayed provider reads. */
class PhotoNp3StateInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val report = Bundle()
        val raw = targetContext.getSharedPreferences("photo_np3_state_test", Context.MODE_PRIVATE)
        raw.edit().clear().commit()
        val store = PhotoNp3Store(raw)
        val source = FakeSource()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        var state: PhotoNp3EditorState? = null
        try {
            checkPreviewAndExportPixels()
            val a = PresetFile(Uri.parse("content://np3-test/document/a"), "A.NP3", 100, 1)
            val b = PresetFile(Uri.parse("content://np3-test/document/b"), "B.np3", 100, 1)
            val original = recipe('a')
            val other = recipe('b')
            val changed = recipe('c')
            val notices = mutableListOf<Int>()
            val selections = mutableListOf<Pair<String, Boolean>>()
            var unavailable = 0
            var ownerEnabled = false
            var ownerActive = true
            source.files = listOf(a, b)
            store.folders.replaceFolder(Uri.parse("content://np3-test/tree/folder"), false)
            val editor = main {
                PhotoNp3EditorState(store, source, "transfer", null, scope,
                    onSelected = { preset, explicit ->
                        selections += preset.id to explicit
                        if (explicit) ownerEnabled = true
                    },
                    onUnavailable = { unavailable++; ownerEnabled = false },
                    notice = { notices += it },
                    selectionAllowed = { ownerActive },
                ).also { state = it; it.refresh() }
            }
            await { !editor.loading }
            main { editor.choose(a) }
            source.nextRead().also { check(it.file == a) }.result.complete(Result.success(original))
            await { !editor.loading }
            main {
                check(editor.selectedPreset == original.preset && editor.selectedUri == a.uri)
                check(selections == listOf(original.preset.id to true) && ownerEnabled)
                store.save("transfer", original.preset, a.uri.toString())
            }

            // A rejected new file never destroys the last successfully applied recipe.
            main { editor.choose(b) }
            source.nextRead().result.complete(Result.failure(PhotoNp3Exception(PhotoNp3Failure.INVALID, "fixture")))
            await { !editor.loading }
            main {
                check(editor.selectedPreset == original.preset && editor.selectedUri == a.uri)
                check(selections.size == 1 && notices.last() == R.string.photo_np3_invalid)
            }

            // Slow providers may ignore cancellation. Their late result must still be discarded.
            main { editor.choose(b) }
            val cancelled = source.nextRead()
            main { editor.cancelPending() }
            cancelled.result.complete(Result.success(other))
            drain()
            main {
                check(editor.selectedPreset == original.preset && editor.selectedUri == a.uri)
                check(selections.size == 1 && editor.pendingUri == null)
            }

            // Pager visibility can change before Compose runs the cancellation effect.
            main { editor.choose(b) }
            val offscreen = source.nextRead()
            main { ownerActive = false }
            offscreen.result.complete(Result.success(other))
            drain()
            main {
                check(editor.selectedPreset == original.preset && editor.selectedUri == a.uri)
                check(selections.size == 1)
                ownerActive = true
            }

            // A complete scan failure is not evidence that the source has been removed.
            source.scanError = PresetFolderException(PresetFolderFailure.READ)
            main { editor.refresh() }
            await { !editor.loading }
            main {
                check(editor.files == listOf(a, b) && editor.selectedPreset == original.preset)
                check(unavailable == 0 && editor.failure == PresetFolderFailure.READ)
            }
            source.scanError = null

            // Refresh applies changed source bytes without pretending the user enabled the filter.
            main { ownerEnabled = false; editor.refresh() }
            source.nextRead().also { check(it.file == a) }.result.complete(Result.success(changed))
            await { !editor.loading }
            main {
                check(editor.selectedPreset == changed.preset && editor.selectedUri == a.uri)
                check(selections.last() == (changed.preset.id to false) && !ownerEnabled)
                check(editor.knownPresetId(a.uri) == changed.preset.id)
            }
            val count = main { selections.size }
            main { editor.refresh() }
            source.nextRead().result.complete(Result.success(changed))
            await { !editor.loading }
            main { check(selections.size == count && !ownerEnabled) }

            // Only a successful complete directory snapshot may confirm disappearance.
            source.files = listOf(b)
            main { editor.refresh() }
            await { !editor.loading }
            main {
                check(editor.selectedPreset == null && editor.selectedUri == null && unavailable == 1)
                check(store.savedId("transfer") == original.preset.id && store.restore("transfer") != null)
            }

            // Off/hidden must also invalidate an in-flight explicit selection.
            main { editor.choose(b) }
            val hidden = source.nextRead()
            main { editor.off() }
            hidden.result.complete(Result.success(other))
            drain()
            main {
                check(editor.selectedPreset == null && editor.selectedUri == null)
                check(selections.size == count && !ownerEnabled)
            }
            checkDirectoryReplacement(store, raw, scope)
            report.putString("result", "PASS: Flexible and all Classic styles preview/export pixels, alpha and restored recipes, explicit/passive choices, unchanged refresh, failure retention, cancellation/late results, inactive owner, confirmed deletion, hidden pending selection; shared directory replacement clears both custom drafts/hints, same directory/failure/cancel retain, stale writes blocked, built-ins retained")
            finish(Activity.RESULT_OK, report)
        } catch (failure: Throwable) {
            report.putString("failure", failure.stackTraceToString())
            finish(Activity.RESULT_CANCELED, report)
        } finally {
            main { state?.close(); scope.cancel() }
            raw.edit().clear().commit()
        }
    }

    private fun checkDirectoryReplacement(
        store: PhotoNp3Store,
        preferences: SharedPreferences,
        scope: CoroutineScope,
    ) {
        val folderA = Uri.parse("content://np3-state/tree/primary%3Afilters-a")
        val folderB = Uri.parse("content://np3-state/tree/primary%3Afilters-b")
        val folderC = Uri.parse("content://np3-state/tree/primary%3Afilters-c")
        fun file(folder: Uri, name: String) = PresetFile(DocumentsContract.buildDocumentUriUsingTree(
            folder, DocumentsContract.getTreeDocumentId(folder) + "/$name"), name, 100, 1)
        val a = file(folderA, "A.NP3")
        val b = file(folderA, "B.NP3")
        val c = file(folderB, "C.NP3")
        val first = recipe('d')
        val second = recipe('e')
        val third = recipe('f')
        val source = FakeSource().apply { files = listOf(a, b) }
        val editors = mutableListOf<PhotoNp3EditorState>()
        val unavailable = mutableListOf<String>()
        val notices = mutableListOf<Int>()
        fun editor(role: String) = main {
            PhotoNp3EditorState(store, source, role, store.restore(role), scope,
                onSelected = { _, _ -> error("An unchanged refresh should not replace the recipe") },
                onUnavailable = { unavailable += role }, notice = { notices += it },
            ).also { editors += it; it.refresh() }
        }
        try {
            main {
                store.folders.replaceFolder(folderA, false)
                store.save("transfer", first.preset, a.uri.toString())
                store.save("local", second.preset, b.uri.toString())
                store.rememberSource(a.uri.toString(), first.sourceSha256, first.preset.id)
                store.rememberSource(b.uri.toString(), second.sourceSha256, second.preset.id)
            }
            val transfer = editor("transfer")
            source.nextRead().also { check(it.file == a) }.result.complete(Result.success(first))
            await { !transfer.loading }
            val local = editor("local")
            source.nextRead().also { check(it.file == b) }.result.complete(Result.success(second))
            await { !local.loading }
            main { transfer.folderPicked(folderA) }
            source.nextRead().result.complete(Result.success(first))
            await { !transfer.loading }
            main {
                check(unavailable.isEmpty())
                check(store.restore("transfer")?.id == first.preset.id)
                check(store.knownPresetId(a.uri.toString()) == first.preset.id)
            }
            source.scanError = PresetFolderException(PresetFolderFailure.READ)
            main { transfer.folderPicked(folderB) }
            await { !transfer.loading }
            source.scanError = null
            main {
                check(unavailable.isEmpty() && notices.size == 1)
                check(store.folders.folder == folderA)
                transfer.folderPicked(folderB)
                transfer.cancelPending()
            }
            drain()
            main {
                check(store.folders.folder == folderA && unavailable.isEmpty())
                check(store.restore("local")?.id == second.preset.id)
            }

            source.files = listOf(c)
            main { transfer.folderPicked(folderB) }
            await { !transfer.loading }
            main {
                check(unavailable.sorted() == listOf("local", "transfer"))
                check(transfer.selectedPreset == null && local.selectedPreset == null)
                check(transfer.selectedUri == null && local.selectedUri == null)
                check(transfer.folder == folderB && local.folder == folderB)
                check(transfer.files == listOf(c) && local.files.isEmpty())
                check(store.restore("transfer") == null && store.restore("local") == null)
                check(store.knownPresetId(a.uri.toString()) == null)
                check(store.knownPresetId(b.uri.toString()) == null)
                // A retained page's later save must not resurrect an old custom snapshot,
                // including when its source association was already cleared by the observer.
                store.save("transfer", first.preset, a.uri.toString())
                store.save("local", second.preset, null)
                check(store.restore("transfer") == null && store.restore("local") == null)
                store.save("transfer", third.preset, c.uri.toString())
                store.save("transfer", first.preset, a.uri.toString())
                check(store.restore("transfer")?.id == third.preset.id)
                // Guard snapshots left by an older build that changed only the directory key.
                preferences.edit().putString("local:id", second.preset.id)
                    .putString("local:uri", b.uri.toString())
                    .putString("local:snapshot", java.util.Base64.getEncoder().encodeToString(
                        PhotoNp3SnapshotCodec.encode(second.preset))).apply()
                check(store.restore("local") == null && store.uri("local") == null)
                store.save("local", second.preset, null)
                check(store.restore("local") == null)
            }

            // Built-in identities are shared with exact source copies. Preserve their selections
            // and parameters while dropping only the now-obsolete directory association.
            val builtIn = BuiltInPhotoFilters.all.first()
            main {
                store.save("transfer", builtIn, null)
                store.save("local", builtIn, c.uri.toString())
                transfer.resetSelection(builtIn)
                local.resetSelection(builtIn, c.uri.toString())
            }
            source.files = emptyList()
            main { transfer.folderPicked(folderC) }
            await { !transfer.loading }
            main {
                check(unavailable.size == 2)
                check(transfer.selectedPreset == builtIn && local.selectedPreset == builtIn)
                check(transfer.selectedUri == null && local.selectedUri == null)
                check(store.restore("transfer") == builtIn && store.restore("local") == builtIn)
            }
        } finally {
            main { editors.forEach(PhotoNp3EditorState::close) }
        }
    }

    private fun checkPreviewAndExportPixels() {
        val preset = recipe('e').preset.let { original ->
            original.copy(parameters = (original.parameters as Np3PhotoFilterParameters).copy(
                contrast = 18, highlights = -20, saturation = 35,
                colorBands = PHOTO_FILTER_COLOR_BAND_CENTERS.mapIndexed { index, center ->
                    PhotoFilterColorBand(center, index * 4 - 12, index * 6 - 15, 10 - index * 3)
                },
            ))
        }
        checkRecipePixels(preset, 72, useExactMemo = true)

        // Exercise both old/new recipe kinds through the same Android pixel pipeline. The full
        // matrix uses the production low-memory path so it does not churn a 64 MB memo per case.
        for (base in ClassicNp3Style.entries) {
            for (curve in listOf<IntArray?>(null, IntArray(257) { i ->
                // A non-linear monotone curve with retained black and white endpoints.
                ((i / 256f) * (i / 256f) * 32767).toInt()
            })) {
                val parameters = ClassicNp3PhotoFilterParameters(
                    base = base,
                    contrastQuarter = 5,
                    brightnessQuarter = -2,
                    saturationQuarter = if (base.monochrome) 0 else 3,
                    hueQuarter = if (base.monochrome) 0 else -1,
                    filterEffect = if (base.monochrome) 3 else 0,
                    toningEffect = if (base.monochrome && !base.creative) 2 else 0,
                    toningDensityQuarter = if (base.monochrome) 21 else 0,
                    effectLevel = if (base.creative) 60 else 100,
                    toneCurve = curve,
                )
                val classic = PhotoFilterPreset(
                    "np3:${base.id.toString(16).padStart(64, '0')}:${PhotoNp3Parser.CLASSIC_CONVERTER_VERSION}",
                    "Classic ${base.name}", parameters,
                )
                for (strength in listOf(2, 74, 100)) checkRecipePixels(classic, strength)
                if (curve == null && base in listOf(ClassicNp3Style.MONOCHROME, ClassicNp3Style.RED)) {
                    checkRecipePixels(classic, 74, useExactMemo = true)
                }
                if (curve == null && !base.monochrome) {
                    checkRecipePixels(classic.copy(parameters = parameters.copy(
                        contrastQuarter = CLASSIC_PHOTO_FILTER_AUTO,
                        saturationQuarter = CLASSIC_PHOTO_FILTER_AUTO,
                    )), 74)
                }
            }
        }
    }

    private fun checkRecipePixels(preset: PhotoFilterPreset, strength: Int, useExactMemo: Boolean = false) {
        val restored = PhotoNp3SnapshotCodec.decode(PhotoNp3SnapshotCodec.encode(preset))
        val pixels = IntArray(64 * 64) { i ->
            android.graphics.Color.argb(
                when (i % 4) { 0 -> 0; 1 -> 64; 2 -> 128; else -> 255 },
                i * 17 % 256, i * 31 % 256, i * 43 % 256,
            )
        }
        val source = android.graphics.Bitmap.createBitmap(pixels, 64, 64, android.graphics.Bitmap.Config.ARGB_8888)
        // Android may quantize RGB while premultiplying translucent pixels. Compare against
        // what the renderer actually reads, rather than the pre-bitmap fixture channels.
        source.getPixels(pixels, 0, 64, 0, 0, 64, 64)
        val export = source.copy(android.graphics.Bitmap.Config.ARGB_8888, true)
        var preview: android.graphics.Bitmap? = null
        try {
            preview = PhotoFilterRenderer.render(source, PhotoFilterSelection(preset, strength))
            val selection = PhotoFilterSelection(restored, strength)
            if (useExactMemo) {
                PhotoFilterRenderer.renderInPlace(export, selection)
            } else {
                PhotoFilterRenderer.renderInPlace(export, PhotoFilterRenderer.PreparedOriginalFilter(
                    selection, null, PhotoFilterRenderer.PreparationMode.DIRECT_FALLBACK,
                ))
            }
            val a = IntArray(pixels.size)
            val b = IntArray(pixels.size)
            preview.getPixels(a, 0, 64, 0, 0, 64, 64)
            export.getPixels(b, 0, 64, 0, 0, 64, 64)
            check(a.contentEquals(b)) { "Restored ${preset.name} export differs from preview at $strength%" }
            check(a.indices.all { (a[it] ushr 24) == (pixels[it] ushr 24) }) {
                "${preset.name} changed photo alpha"
            }
            check(!a.contentEquals(pixels)) { "Non-neutral ${preset.name} did not change pixels at $strength%" }
        } finally {
            preview?.recycle(); export.recycle(); source.recycle()
        }
    }

    private fun recipe(digest: Char): ParsedPhotoNp3 {
        val hash = digest.toString().repeat(64)
        return ParsedPhotoNp3(hash, PhotoFilterPreset("np3:$hash:np3-srgb-v1", "Fixture $digest",
            Np3PhotoFilterParameters(0, 0, 0, 0, 0, 0,
                PHOTO_FILTER_COLOR_BAND_CENTERS.map { PhotoFilterColorBand(it, 0, 0, 0) })),
            ignoredDetailControls = false)
    }

    private fun <T> main(block: () -> T): T {
        var value: Result<T>? = null
        runOnMainSync { value = runCatching(block) }
        return checkNotNull(value).getOrThrow()
    }

    private fun await(condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 4000
        while (!main(condition)) {
            check(SystemClock.uptimeMillis() < deadline) { "NP3 state did not settle" }
            SystemClock.sleep(10)
        }
    }

    private fun drain() {
        val done = CountDownLatch(1)
        main { PresetIoQueue.submit({ Unit }) { done.countDown() } }
        check(done.await(4, TimeUnit.SECONDS)) { "NP3 IO queue did not settle" }
    }

    private class FakeSource : PhotoNp3Source {
        data class Read(val file: PresetFile,
            val result: CompletableDeferred<Result<ParsedPhotoNp3>> = CompletableDeferred())
        val reads = Channel<Read>(Channel.UNLIMITED)
        @Volatile var files = emptyList<PresetFile>()
        @Volatile var scanError: Exception? = null
        override suspend fun scan(uri: Uri, replacing: Boolean, signal: CancellationSignal): PresetFolderSnapshot {
            scanError?.let { throw it }
            return PresetFolderSnapshot(files, false)
        }
        override suspend fun read(file: PresetFile, signal: CancellationSignal): ParsedPhotoNp3 {
            val pending = Read(file)
            reads.send(pending)
            return pending.result.await().getOrThrow()
        }
        override fun releaseGrant(uri: Uri) = Unit
        fun nextRead() = runBlocking { withTimeout(4000) { reads.receive() } }
    }
}
