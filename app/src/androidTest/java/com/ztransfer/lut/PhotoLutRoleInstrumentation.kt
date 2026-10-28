package com.ztransfer.lut

import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.net.Uri
import android.os.Bundle
import android.os.CancellationSignal
import android.os.SystemClock
import android.provider.DocumentsContract
import com.ztransfer.filter.LutAdjustments
import com.ztransfer.filter.PhotoFilterSelection
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import java.io.File

/** Actual store/editor migration and reconnect, using only disposable private files and prefs. */
class PhotoLutRoleInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val report = Bundle()
        var outcome = Activity.RESULT_CANCELED
        val context = FixtureContext(targetContext)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val editors = mutableListOf<PhotoLutEditorState>()
        try {
            val oldFolder = Uri.parse("content://photo-lut-role-test/tree/old")
            val newFolder = Uri.parse("content://photo-lut-role-test/tree/new")
            fun file(tree: Uri, id: String) = LutFile(
                DocumentsContract.buildDocumentUriUsingTree(tree, id), "$id.cube", 100, 1,
            )
            val a = file(oldFolder, "a")
            val b = file(oldFolder, "b")
            val c = file(newFolder, "c")
            fun table(name: String) = CubeLutParser.parse(("TITLE \"$name\"\nLUT_3D_SIZE 2\n" +
                "0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n").byteInputStream())
            val tables = mapOf(a.uri to table("a"), b.uri to table("b"), c.uri to table("c"))
            val raw = context.getSharedPreferences("photo_lut", Context.MODE_PRIVATE)
            val transferOld = LutAdjustments(10, -10, 5, -5)
            val localOld = LutAdjustments(-20, 25, -10, 10)
            val legacyOther = LutAdjustments(30, 20, 10, 0)
            val digest = tables.getValue(a.uri).digest
            // Build an old-install fixture without calling the new migration or save methods.
            val directory = File(context.filesDir, "photo-lut-snapshots").apply { mkdirs() }
            tables.values.forEach { value ->
                File(directory, "${value.digest}.bin").outputStream().use { PhotoLutSnapshotCodec.write(value, it) }
            }
            fun SharedPreferences.Editor.controls(prefix: String, value: LutAdjustments) {
                putInt("$prefix:contrast", value.contrast)
                putInt("$prefix:saturation", value.saturation)
                putInt("$prefix:highlights", value.highlights)
                putInt("$prefix:shadows", value.shadows)
            }
            raw.edit().apply {
                putString("remote_lut_folder", oldFolder.toString())
                putInt("lut_adjustments_v1:$digest:intensity", 72)
                controls("lut_adjustments_v1:$digest", legacyOther)
                putInt("strength:${b.uri}", 66)
                controls("lut_adjustments_v1:${tables.getValue(b.uri).digest}", legacyOther)
                for ((role, strength, adjustment) in listOf(
                    Triple("transfer", 42, transferOld), Triple("local", 88, localOld),
                )) {
                    putString("$role:digest", digest); putString("$role:name", "a")
                    putString("$role:uri", a.uri.toString()); putInt("$role:strength", strength)
                    controls("$role:adjustments", adjustment)
                }
            }.commit()
            val store = PhotoLutStore(context)
            fun expect(selection: PhotoFilterSelection?, strength: Int, adjustments: LutAdjustments) {
                check(selection != null && selection.normalizedIntensityPercent == strength &&
                    selection.lutAdjustments == adjustments) { "Wrong role recipe: $selection" }
            }
            // First action after upgrade is Off: it must preserve this role's old recipe first.
            store.save("transfer", null, null)
            check(store.restore("transfer") == null)
            val transfer = store.snapshot("transfer", a, tables.getValue(a.uri))
            expect(transfer, 42, transferOld)
            expect(store.snapshot("local", a, tables.getValue(a.uri)), 88, localOld)
            expect(store.snapshot("transfer", b, tables.getValue(b.uri)), 66, legacyOther)
            store.rememberIntensity("transfer", tables.getValue(b.uri).digest, b.uri.toString(), 54)
            store.rememberAdjustments("transfer", tables.getValue(b.uri).digest, LutAdjustments())
            // An unmigrated second role must see old shared values, never the new first-role edit.
            expect(store.snapshot("local", b, tables.getValue(b.uri)), 66, legacyOther)
            store.save("transfer", transfer, a.uri.toString())
            check(store.folders.folder == PhotoLutStore(context).folders.folder)
            check(raw.getInt("lut_adjustments_v1:$digest:intensity", 0) == 72)

            val source = object : LutSource {
                var entries = listOf(a, b)
                var failure: LutFolderFailure? = null
                override suspend fun scan(tree: Uri, replacing: Boolean, signal: CancellationSignal): LutFolderSnapshot {
                    failure?.let { throw LutFolderException(it) }
                    return LutFolderSnapshot(entries, false)
                }
                override suspend fun read(file: LutFile, signal: CancellationSignal) = tables.getValue(file.uri)
                override fun releaseGrant(uri: Uri) = Unit
            }
            val notices = mutableListOf<Pair<String, Int>>()
            fun editor(role: String): PhotoLutEditorState = main {
                val restoredStore = PhotoLutStore(context)
                PhotoLutEditorState(role, restoredStore, source, scope,
                    restoredStore.restore(role), restoredStore.uri(role), {},
                    { notices += role to it }).also { editors += it; it.refresh() }
            }
            var transferEditor = editor("transfer")
            val localEditor = editor("local")
            await { !transferEditor.loading && !localEditor.loading }
            val adjusted = LutAdjustments(40, -30, 20, -10)
            main { transferEditor.strength(50); transferEditor.adjustments(adjusted) }
            val queued = main { checkNotNull(transferEditor.selection) }
            main { localEditor.strength(92); localEditor.adjustments(LutAdjustments()) }
            main { transferEditor.off(); transferEditor.choose(a.uri) }
            await { !transferEditor.loading }
            expect(main { transferEditor.selection }, 50, adjusted)
            main { localEditor.off(); localEditor.choose(a.uri) }
            await { !localEditor.loading }
            expect(main { localEditor.selection }, 92, LutAdjustments())
            main { localEditor.choose(b.uri) }
            await { !localEditor.loading }
            expect(main { localEditor.selection }, 66, legacyOther)
            expect(queued, 50, adjusted)
            main {
                store.save("transfer", transferEditor.selection, transferEditor.selectedUri?.toString())
                store.save("local", localEditor.selection, localEditor.selectedUri?.toString())
            }
            expect(PhotoLutStore(context).restore("transfer"), 50, adjusted)
            expect(PhotoLutStore(context).restore("local"), 66, legacyOther)
            check(store.uri("transfer") == a.uri.toString() && store.uri("local") == b.uri.toString())

            // Same directory, cancellation and a failed replacement retain all role settings.
            store.toggleFavorite(a.uri.toString())
            main { localEditor.folderPicked(oldFolder) }
            await { !localEditor.loading }
            expect(main { localEditor.selection }, 66, legacyOther)
            main { localEditor.cancelPending() }
            expect(main { transferEditor.selection }, 50, adjusted)
            main { source.failure = LutFolderFailure.DENIED; localEditor.folderPicked(newFolder) }
            await { !localEditor.loading }
            expect(main { localEditor.selection }, 66, legacyOther)
            check(store.folders.folder == oldFolder && store.favorites().isNotEmpty())
            main { source.failure = null }

            // A successful new directory clears both roles and all old-directory memories.
            main { source.entries = listOf(c); localEditor.folderPicked(newFolder) }
            await { !localEditor.loading && transferEditor.selection == null }
            check(main { localEditor.selection } == null)
            check(PhotoLutStore(context).folders.folder == newFolder)
            check(store.restore("transfer") == null && store.restore("local") == null)
            check(store.favorites().isEmpty())
            check(raw.all.keys.none { it.startsWith("lut_adjustments_") || it.startsWith("strength:") })
            expect(queued, 50, adjusted) // Running/queued snapshots remain unchanged.
            store.save("transfer", queued, a.uri.toString())
            check(store.restore("transfer") == null) // A stale editor cannot re-enable the old source.
            main { transferEditor.close() }
            transferEditor = editor("transfer")
            await { !transferEditor.loading }
            check(main { transferEditor.selection } == null)
            main { transferEditor.choose(c.uri) }
            await { !transferEditor.loading }
            expect(main { transferEditor.selection }, 80, LutAdjustments())

            // Returning to the old directory is a new selection, with fresh default values.
            main { source.entries = listOf(a); transferEditor.folderPicked(oldFolder) }
            await { !transferEditor.loading }
            main { transferEditor.choose(a.uri) }
            await { !transferEditor.loading }
            expect(main { transferEditor.selection }, 80, LutAdjustments())
            main { transferEditor.strength(42); transferEditor.adjustments(adjusted) }
            main { transferEditor.strength(80); transferEditor.adjustments(LutAdjustments()) }
            main { transferEditor.off(); transferEditor.choose(a.uri) }
            await { !transferEditor.loading }
            expect(main { transferEditor.selection }, 80, LutAdjustments())
            // Genuine deletion in the current directory still switches Off.
            main { source.entries = emptyList(); transferEditor.refresh() }
            await { !transferEditor.loading }
            check(main { transferEditor.selection } == null)
            check(main { notices.size } == 1)
            report.putString("result", "PASS: shared directory; per-role selection/parameters; upgrade migration; same/failed/cancelled directory preservation; synchronous two-role reset; old-directory parameters and favorites discarded; stale-save guard; restart; default/reset/reselect; queued snapshot and deletion")
            outcome = Activity.RESULT_OK
        } catch (failure: Throwable) {
            report.putString("failure", failure.stackTraceToString())
        } finally {
            main { editors.forEach { it.close() }; scope.cancel() }
            context.cleanup()
        }
        finish(outcome, report)
    }

    private fun <T> main(block: () -> T): T {
        var result: Result<T>? = null
        runOnMainSync { result = runCatching(block) }
        return checkNotNull(result).getOrThrow()
    }
    private fun await(condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 6_000
        while (!main(condition) && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(20)
        check(main(condition)) { "LUT editor did not settle" }
    }
    private class FixtureContext(base: Context) : ContextWrapper(base) {
        private val prefix = "photo_lut_roles_${SystemClock.elapsedRealtimeNanos()}_"
        private val names = mutableSetOf<String>()
        override fun getApplicationContext(): Context = this
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
            super.getSharedPreferences(prefix + name, mode).also { names += prefix + name }
        override fun getFilesDir() = File(super.getFilesDir(), prefix).apply { mkdirs() }
        fun cleanup() { names.forEach { baseContext.deleteSharedPreferences(it) }; filesDir.deleteRecursively() }
    }
}
