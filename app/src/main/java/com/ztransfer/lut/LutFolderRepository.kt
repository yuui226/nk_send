package com.ztransfer.lut

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.CancellationSignal
import android.provider.DocumentsContract
import java.io.FileNotFoundException
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

internal data class LutFile(
    val uri: Uri,
    val name: String,
    val size: Long?,
    val modified: Long?,
) {
    val label: String get() = name.dropLast(5)
}

internal enum class LutFolderFailure { MISSING, DENIED, READ, TOO_MANY }
internal class LutFolderException(val reason: LutFolderFailure, cause: Throwable? = null) :
    IOException(reason.name, cause)

internal data class LutFolderSnapshot(val files: List<LutFile>, val acquired: Boolean)

internal interface LutSource {
    suspend fun scan(tree: Uri, replacing: Boolean, signal: CancellationSignal): LutFolderSnapshot
    suspend fun read(file: LutFile, signal: CancellationSignal): CubeLut
    fun releaseGrant(uri: Uri)
}

/** Metadata-only enumeration. A failed enumeration never returns a partial list. */
internal class LutFolderRepository(private val resolver: ContentResolver) : LutSource {
    override suspend fun scan(tree: Uri, replacing: Boolean, signal: CancellationSignal): LutFolderSnapshot =
        withContext(Dispatchers.IO) {
            var acquired = false
            var success = false
            try {
                if (replacing) {
                    val held = resolver.persistedUriPermissions.any { it.uri == tree && it.isReadPermission }
                    resolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    acquired = !held
                }
                LutFolderSnapshot(enumerate(tree, signal), acquired).also { success = true }
            } finally {
                if (!success && acquired) releaseGrant(tree)
            }
        }

    override fun releaseGrant(uri: Uri) {
        // A write grant may belong to the transfer destination; never revoke its shared access.
        try {
            if (resolver.persistedUriPermissions.none { it.uri == uri && it.isWritePermission }) {
                resolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        } catch (_: Exception) { /* Already revoked by the provider or user. */ }
    }

    private suspend fun enumerate(tree: Uri, signal: CancellationSignal): List<LutFile> = withContext(Dispatchers.IO) {
        try {
            val context = currentCoroutineContext()
            context.ensureActive()
            val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
            resolver.query(root, arrayOf(DocumentsContract.Document.COLUMN_MIME_TYPE), null, null, null, signal)
                ?.use { cursor ->
                    if (!cursor.moveToFirst()) throw LutFolderException(LutFolderFailure.MISSING)
                    if (cursor.getString(0) != DocumentsContract.Document.MIME_TYPE_DIR) {
                        throw LutFolderException(LutFolderFailure.MISSING)
                    }
                } ?: throw LutFolderException(LutFolderFailure.READ)
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
            val columns = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            )
            val files = ArrayList<LutFile>()
            resolver.query(children, columns, null, null, null, signal)?.use { cursor ->
                var total = 0
                while (cursor.moveToNext()) {
                    context.ensureActive()
                    signal.throwIfCanceled()
                    if (++total > 10_000) throw LutFolderException(LutFolderFailure.TOO_MANY)
                    val name = cursor.getString(1) ?: continue
                    if (cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR ||
                        !name.endsWith(".cube", ignoreCase = true)) continue
                    val id = cursor.getString(0) ?: throw LutFolderException(LutFolderFailure.READ)
                    files.add(LutFile(
                        DocumentsContract.buildDocumentUriUsingTree(tree, id), name,
                        if (cursor.isNull(3)) null else cursor.getLong(3).takeIf { it >= 0 },
                        if (cursor.isNull(4)) null else cursor.getLong(4).takeIf { it > 0 },
                    ))
                }
            } ?: throw LutFolderException(LutFolderFailure.READ)
            files.sortedWith(compareBy<LutFile, String>(String.CASE_INSENSITIVE_ORDER) { it.name }
                .thenBy { it.name }.thenBy { it.uri.toString() })
        } catch (e: CancellationException) {
            throw e
        } catch (e: LutFolderException) {
            throw e
        } catch (e: SecurityException) {
            throw LutFolderException(LutFolderFailure.DENIED, e)
        } catch (e: FileNotFoundException) {
            throw LutFolderException(LutFolderFailure.MISSING, e)
        } catch (e: Exception) {
            currentCoroutineContext().ensureActive()
            throw LutFolderException(LutFolderFailure.READ, e)
        }
    }

    override suspend fun read(file: LutFile, signal: CancellationSignal): CubeLut = withContext(Dispatchers.IO) {
        val context = currentCoroutineContext()
        context.ensureActive()
        if ((file.size ?: 0) > CubeLutParser.MAX_BYTES) {
            throw LutException(LutFailure.TOO_LARGE, "LUT exceeds file limit")
        }
        // A cancellable descriptor also permits virtual/cloud providers to abort opening the file.
        resolver.openAssetFileDescriptor(file.uri, "r", signal)?.use { descriptor ->
            descriptor.createInputStream().use { input ->
                CubeLutParser.parse(input) {
                    context.ensureActive()
                    signal.throwIfCanceled()
                }
            }
        } ?: throw LutException(LutFailure.READ, "Provider did not return a stream")
    }
}
