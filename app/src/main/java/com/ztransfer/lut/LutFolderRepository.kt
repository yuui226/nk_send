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
    val category: String? = null,
) {
    val label: String get() = name.dropLast(5)
}

/** Stable labels are based on folder order, independent of favorite reordering. */
internal fun lutFileLabels(files: List<LutFile>, uncategorized: String = ""): Map<Uri, String> {
    val counts = files.groupingBy { it.label.lowercase(java.util.Locale.ROOT) }.eachCount()
    val categoryCounts = files.groupingBy { it.label.lowercase(java.util.Locale.ROOT) to it.category }.eachCount()
    val positions = mutableMapOf<String, Int>()
    return files.associate { file ->
        val name = file.label.ifEmpty { file.name }.take(256)
        val group = file.label.lowercase(java.util.Locale.ROOT)
        val position = (positions[group] ?: 0) + 1
        positions[group] = position
        val category = file.category ?: uncategorized
        val duplicateInCategory = (categoryCounts[group to file.category] ?: 0) > 1
        file.uri to if ((counts[group] ?: 0) > 1) {
            listOf(name, category, if (duplicateInCategory) position.toString() else "")
                .filter(String::isNotEmpty).joinToString(" · ")
        } else name
    }
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
internal class LutFolderRepository(
    private val resolver: ContentResolver,
    private val sharedGrant: (Uri) -> Boolean = { false },
) : LutSource {
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
            if (sharedGrant(uri)) return
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
            val rootId = DocumentsContract.getTreeDocumentId(tree)
            val columns = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            )
            val files = ArrayList<LutFile>()
            var total = 0
            val folders = ArrayList<Pair<String, String>>()
            val seenDirectories = hashSetOf(rootId)
            val seenFiles = HashSet<String>()
            fun readDirectory(id: String, category: String?, collectFolders: Boolean) {
                val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
                resolver.query(children, columns, null, null, null, signal)?.use { cursor ->
                    while (cursor.moveToNext()) {
                        context.ensureActive()
                        signal.throwIfCanceled()
                        if (++total > 10_000) throw LutFolderException(LutFolderFailure.TOO_MANY)
                        val name = cursor.getString(1) ?: continue
                        val childId = cursor.getString(0) ?: throw LutFolderException(LutFolderFailure.READ)
                        if (cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) {
                            if (collectFolders && seenDirectories.add(childId)) folders.add(childId to name)
                            continue
                        }
                        if (!name.endsWith(".cube", ignoreCase = true) || !seenFiles.add(childId)) continue
                        files.add(LutFile(
                            DocumentsContract.buildDocumentUriUsingTree(tree, childId), name,
                            if (cursor.isNull(3)) null else cursor.getLong(3).takeIf { it >= 0 },
                            if (cursor.isNull(4)) null else cursor.getLong(4).takeIf { it > 0 },
                            category,
                        ))
                    }
                } ?: throw LutFolderException(LutFolderFailure.READ)
            }
            readDirectory(rootId, null, true)
            // Only one level; publish atomically so an unreadable child never looks deleted.
            for ((id, name) in folders) {
                try {
                    readDirectory(id, name, false)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    context.ensureActive()
                    // A missing/denied child is not a revoked root grant. Keep the previous
                    // snapshot and active LUT instead of letting state clear the whole folder.
                    if (e is LutFolderException && e.reason == LutFolderFailure.TOO_MANY) throw e
                    throw LutFolderException(LutFolderFailure.READ, e)
                }
            }
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

    private fun metadata(file: LutFile, signal: CancellationSignal): Pair<Long?, Long?> {
        val columns = arrayOf(DocumentsContract.Document.COLUMN_SIZE, DocumentsContract.Document.COLUMN_LAST_MODIFIED)
        return resolver.query(file.uri, columns, null, null, null, signal)?.use { cursor ->
            if (!cursor.moveToFirst()) throw FileNotFoundException(file.name)
            val size = if (cursor.isNull(0)) null else cursor.getLong(0).takeIf { it > 0 }
            val modified = if (cursor.isNull(1)) null else cursor.getLong(1).takeIf { it > 0 }
            size to modified
        } ?: (null to null)
    }

    private companion object {
        val parsedCache = ParsedLutCache()
    }

    override suspend fun read(file: LutFile, signal: CancellationSignal): CubeLut = withContext(Dispatchers.IO) {
        val context = currentCoroutineContext()
        context.ensureActive()
        signal.throwIfCanceled()
        val key = file.uri.toString()
        // Always ask the provider, including on cache hits: revoked access or edited files
        // must not silently use an old table. Unknown metadata deliberately bypasses caching.
        val stamp = try { metadata(file, signal) } catch (failure: Exception) {
            parsedCache.remove(key)
            throw failure
        }
        context.ensureActive()
        signal.throwIfCanceled()
        if ((stamp.first ?: 0) > CubeLutParser.MAX_BYTES) {
            parsedCache.remove(key)
            throw LutException(LutFailure.TOO_LARGE, "LUT exceeds file limit")
        }
        parsedCache.get(key, stamp.first, stamp.second)?.let {
            context.ensureActive()
            signal.throwIfCanceled()
            return@withContext it
        }
        // A cancellable descriptor also permits virtual/cloud providers to abort opening the file.
        val table = resolver.openAssetFileDescriptor(file.uri, "r", signal)?.use { descriptor ->
            descriptor.createInputStream().use { input ->
                CubeLutParser.parse(input) {
                    context.ensureActive()
                    signal.throwIfCanceled()
                }
            }
        } ?: throw LutException(LutFailure.READ, "Provider did not return a stream")
        context.ensureActive()
        signal.throwIfCanceled()
        if (stamp.first != null && stamp.second != null && metadata(file, signal) == stamp) {
            parsedCache.put(key, stamp.first, stamp.second, table)
        }
        table
    }
}
