package com.ztransfer.presets

import com.ztransfer.R
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

internal data class PresetFile(
    val uri: Uri,
    val name: String,
    val size: Long?,
    val modified: Long?,
    val category: String? = null,
) {
    val label: String get() = name.substringBeforeLast('.', name)
}

/** Stable labels are based on folder order, independent of favorite reordering. */
internal fun presetFileLabels(files: List<PresetFile>, uncategorized: String = ""): Map<Uri, String> {
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

internal enum class PresetFolderFailure { MISSING, DENIED, READ, TOO_MANY }
internal class PresetFolderException(val reason: PresetFolderFailure, cause: Throwable? = null) :
    IOException(reason.name, cause)

internal data class PresetFolderSnapshot(val files: List<PresetFile>, val acquired: Boolean)

/** Metadata-only enumeration. A failed enumeration never returns a partial list. */
internal class PresetFolderRepository(
    private val resolver: ContentResolver,
    private val extension: String,
    private val sharedGrant: (Uri) -> Boolean = { false },
) {
    suspend fun scan(tree: Uri, replacing: Boolean, signal: CancellationSignal): PresetFolderSnapshot =
        withContext(Dispatchers.IO) {
            var acquired = false
            var success = false
            try {
                if (replacing) {
                    val held = resolver.persistedUriPermissions.any { it.uri == tree && it.isReadPermission }
                    resolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    acquired = !held
                }
                PresetFolderSnapshot(enumerate(tree, signal), acquired).also { success = true }
            } finally {
                if (!success && acquired) releaseGrant(tree)
            }
        }

    fun releaseGrant(uri: Uri) {
        // A write grant may belong to the transfer destination; never revoke its shared access.
        try {
            if (sharedGrant(uri)) return
            if (resolver.persistedUriPermissions.none { it.uri == uri && it.isWritePermission }) {
                resolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        } catch (_: Exception) { /* Already revoked by the provider or user. */ }
    }

    private suspend fun enumerate(tree: Uri, signal: CancellationSignal): List<PresetFile> = withContext(Dispatchers.IO) {
        try {
            val context = currentCoroutineContext()
            context.ensureActive()
            val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
            resolver.query(root, arrayOf(DocumentsContract.Document.COLUMN_MIME_TYPE), null, null, null, signal)
                ?.use { cursor ->
                    if (!cursor.moveToFirst()) throw PresetFolderException(PresetFolderFailure.MISSING)
                    if (cursor.getString(0) != DocumentsContract.Document.MIME_TYPE_DIR) {
                        throw PresetFolderException(PresetFolderFailure.MISSING)
                    }
                } ?: throw PresetFolderException(PresetFolderFailure.READ)
            val rootId = DocumentsContract.getTreeDocumentId(tree)
            val columns = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            )
            val files = ArrayList<PresetFile>()
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
                        if (++total > 10_000) throw PresetFolderException(PresetFolderFailure.TOO_MANY)
                        val name = cursor.getString(1) ?: continue
                        val childId = cursor.getString(0) ?: throw PresetFolderException(PresetFolderFailure.READ)
                        if (cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) {
                            if (collectFolders && seenDirectories.add(childId)) folders.add(childId to name)
                            continue
                        }
                        if (!name.endsWith(extension, ignoreCase = true) || !seenFiles.add(childId)) continue
                        files.add(PresetFile(
                            DocumentsContract.buildDocumentUriUsingTree(tree, childId), name,
                            if (cursor.isNull(3)) null else cursor.getLong(3).takeIf { it >= 0 },
                            if (cursor.isNull(4)) null else cursor.getLong(4).takeIf { it > 0 },
                            category,
                        ))
                    }
                } ?: throw PresetFolderException(PresetFolderFailure.READ)
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
                    // snapshot instead of letting state clear the whole folder.
                    if (e is PresetFolderException && e.reason == PresetFolderFailure.TOO_MANY) throw e
                    throw PresetFolderException(PresetFolderFailure.READ, e)
                }
            }
            files.sortedWith(compareBy<PresetFile, String>(String.CASE_INSENSITIVE_ORDER) { it.name }
                .thenBy { it.name }.thenBy { it.uri.toString() })
        } catch (e: CancellationException) {
            throw e
        } catch (e: PresetFolderException) {
            throw e
        } catch (e: SecurityException) {
            throw PresetFolderException(PresetFolderFailure.DENIED, e)
        } catch (e: FileNotFoundException) {
            throw PresetFolderException(PresetFolderFailure.MISSING, e)
        } catch (e: Exception) {
            currentCoroutineContext().ensureActive()
            throw PresetFolderException(PresetFolderFailure.READ, e)
        }
    }

}

internal fun presetFolderMessage(reason: PresetFolderFailure) = when (reason) {
    PresetFolderFailure.MISSING -> R.string.lut_folder_missing
    PresetFolderFailure.DENIED -> R.string.lut_folder_denied
    PresetFolderFailure.READ -> R.string.lut_folder_read_failed
    PresetFolderFailure.TOO_MANY -> R.string.lut_folder_too_many
}
