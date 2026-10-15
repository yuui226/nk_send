package com.ztransfer.presets

import android.app.Activity
import android.app.Instrumentation
import android.content.ContentResolver
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.DocumentsProvider
import com.ztransfer.protocol.builtInPictureControls
import com.ztransfer.protocol.encodeClassicPictureControl
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import java.io.File

/** Actual SAF queries/streams and folder coordinator, isolated from user preferences and grants. */
class PictureControlFolderInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val result = Bundle()
        var outcome = Activity.RESULT_CANCELED
        val scratch = File(targetContext.cacheDir, "picture-control-folder-fixture").apply { mkdirs() }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        var state: PictureControlFolderState? = null
        val preferencesName = "picture_control_folder_test"
        val preferences = targetContext.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        try {
            val builtIns = builtInPictureControls(targetContext.assets)
            for (preset in builtIns) preset.read(targetContext.assets).encodeClassicPictureControl()
            val bytes = builtIns.first().read(targetContext.assets).bytes()
            fun write(path: String, data: ByteArray = bytes) {
                File(scratch, path).apply { parentFile!!.mkdirs(); writeBytes(data) }
            }
            write("root.np3"); write("人像/portrait.NP3"); write("胶片/film.Np3")
            write("ignore.cube"); write("人像/deeper/ignored.NP3")
            val provider = FixtureProvider(scratch)
            provider.attachInfo(targetContext, ProviderInfo().apply {
                authority = "com.ztransfer.debug.test.picturecontrol"
                exported = true; grantUriPermissions = true
                readPermission = "android.permission.MANAGE_DOCUMENTS"
                writePermission = "android.permission.MANAGE_DOCUMENTS"
            })
            val resolver = ContentResolver.wrap(provider)
            val isolated = object : ContextWrapper(targetContext) {
                override fun getApplicationContext(): Context = this
                override fun getContentResolver(): ContentResolver = resolver
                override fun getSharedPreferences(name: String, mode: Int) =
                    targetContext.getSharedPreferences(if (name == "picture_control_folder") preferencesName else "${preferencesName}_$name", mode)
            }
            val tree = DocumentsContract.buildTreeDocumentUri("com.ztransfer.debug.test.picturecontrol", "root")
            preferences.edit().putString("folder", tree.toString()).putBoolean("use_folder", false).commit()
            val notices = mutableListOf<Int>()
            val folders = main { PictureControlFolderState(isolated, scope) { notices += it }.also { state = it } }
            fun refresh() { main { folders.refresh() }; await { !folders.scanning } }
            refresh()
            val original = main { folders.files }
            check(original.map { it.name }.toSet() == setOf("root.np3", "portrait.NP3", "film.Np3"))
            check(original.associate { it.name to it.category } == mapOf("root.np3" to null, "portrait.NP3" to "人像", "film.Np3" to "胶片"))
            runBlocking { for (file in original) check(folders.read(file).bytes().contentEquals(bytes)) }

            // A broken child must not publish a partial scan or revoke access to the entire root.
            provider.denied = "root/人像"
            refresh()
            main { check(folders.failure == PresetFolderFailure.READ && folders.files == original) }
            provider.denied = "root"
            refresh()
            main { check(folders.failure == PresetFolderFailure.DENIED && folders.files == original) }
            provider.denied = null; provider.missing = true
            refresh()
            main { check(folders.failure == PresetFolderFailure.MISSING && folders.files == original) }
            provider.missing = false
            refresh()
            main { check(folders.failure == null && folders.files == original) }

            // Each read uses the current file; a prior valid read cannot hide changed or deleted data.
            val root = original.single { it.category == null }
            fun rejected(reason: PictureControlImportFailure) = runBlocking {
                val error = runCatching { folders.read(root) }.exceptionOrNull()
                check(error is PictureControlImportException && error.reason == reason) { "Expected $reason, got $error" }
            }
            write("root.np3", byteArrayOf(1, 2, 3)); rejected(PictureControlImportFailure.INVALID)
            write("root.np3", targetContext.assets.open("picture_controls/PORTRAIT-02.NP3").use { it.readBytes() })
            rejected(PictureControlImportFailure.UNSUPPORTED)
            check(File(scratch, "root.np3").delete()); rejected(PictureControlImportFailure.READ)
            check(scratch.deleteRecursively() && scratch.mkdirs())
            refresh()
            main { check(folders.files.isEmpty() && folders.failure == null) }
            // The saved folder must be scanned on the next screen instance, regardless of old source toggles.
            write("reopened.NP3")
            main { folders.close(); state = PictureControlFolderState(isolated, scope) { notices += it }; state!!.refresh() }
            await { state?.scanning == false }
            main { check(state!!.files.single().name == "reopened.NP3") }
            check(notices.isEmpty())
            result.putString("result", "PASS: ${builtIns.size} catalog assets, saved-folder migration/reopen, NP3 extension filtering, root/subfolders, atomic failure, denied/missing recovery, changed/unsupported/deleted files, empty folder")
            outcome = Activity.RESULT_OK
        } catch (error: Throwable) {
            result.putString("failure", error.stackTraceToString())
        } finally {
            main { state?.close(); scope.cancel() }
            scratch.deleteRecursively()
            preferences.edit().clear().commit()
        }
        finish(outcome, result)
    }

    private fun <T> main(block: () -> T): T {
        var value: Result<T>? = null
        runOnMainSync { value = runCatching(block) }
        return checkNotNull(value).getOrThrow()
    }
    private fun await(condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 5000
        while (!main(condition)) {
            check(SystemClock.uptimeMillis() < deadline) { "Folder state did not settle" }
            SystemClock.sleep(20)
        }
    }

    private class FixtureProvider(private val root: File) : DocumentsProvider() {
        @Volatile var denied: String? = null
        @Volatile var missing = false
        override fun onCreate() = true
        private val columns = arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE, Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED)
        private fun file(id: String): File {
            if (id == denied) throw SecurityException("Fixture access revoked")
            val file = if (id == "root") root else File(root, id.removePrefix("root/"))
            require(file.canonicalPath == root.canonicalPath || file.canonicalPath.startsWith(root.canonicalPath + "/"))
            return file
        }
        private fun row(cursor: MatrixCursor, file: File) {
            val values = mapOf(Document.COLUMN_DOCUMENT_ID to if (file == root) "root" else "root/${file.relativeTo(root).path}",
                Document.COLUMN_DISPLAY_NAME to file.name,
                Document.COLUMN_MIME_TYPE to if (file.isDirectory) Document.MIME_TYPE_DIR else "application/octet-stream",
                Document.COLUMN_SIZE to file.length(), Document.COLUMN_LAST_MODIFIED to file.lastModified())
            cursor.addRow(cursor.columnNames.map { values[it] }.toTypedArray())
        }
        override fun queryRoots(projection: Array<out String>?): Cursor = MatrixCursor(projection ?: emptyArray())
        override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor =
            MatrixCursor(projection ?: columns).also { cursor ->
                val file = file(documentId)
                if (!missing && file.exists()) row(cursor, file)
            }
        override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?): Cursor =
            MatrixCursor(projection ?: columns).also { cursor -> file(parentDocumentId).listFiles()?.forEach { row(cursor, it) } }
        override fun isChildDocument(parentDocumentId: String, documentId: String) =
            file(documentId).canonicalPath.startsWith(file(parentDocumentId).canonicalPath + "/")
        override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
            signal?.throwIfCanceled()
            return ParcelFileDescriptor.open(file(documentId), ParcelFileDescriptor.MODE_READ_ONLY)
        }
    }
}
