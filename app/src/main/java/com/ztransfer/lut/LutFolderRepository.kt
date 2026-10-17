package com.ztransfer.lut

import android.content.ContentResolver
import android.net.Uri
import android.os.CancellationSignal
import android.provider.DocumentsContract
import java.io.FileNotFoundException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

internal typealias LutFile = com.ztransfer.presets.PresetFile
internal typealias LutFolderFailure = com.ztransfer.presets.PresetFolderFailure
internal typealias LutFolderException = com.ztransfer.presets.PresetFolderException
internal typealias LutFolderSnapshot = com.ztransfer.presets.PresetFolderSnapshot

internal fun lutFileLabels(files: List<LutFile>, uncategorized: String = ""): Map<Uri, String> =
    com.ztransfer.presets.presetFileLabels(files, uncategorized)

internal interface LutSource {
    suspend fun scan(tree: Uri, replacing: Boolean, signal: CancellationSignal): LutFolderSnapshot
    suspend fun read(file: LutFile, signal: CancellationSignal): CubeLut
    fun releaseGrant(uri: Uri)
}

/** LUT parsing uses the same metadata-only folder browser as camera presets. */
internal class LutFolderRepository(
    private val resolver: ContentResolver,
    sharedGrant: (Uri) -> Boolean = { false },
) : LutSource {
    private val folders = com.ztransfer.presets.PresetFolderRepository(resolver, ".cube", sharedGrant)
    override suspend fun scan(tree: Uri, replacing: Boolean, signal: CancellationSignal): LutFolderSnapshot =
        folders.scan(tree, replacing, signal)
    override fun releaseGrant(uri: Uri) = folders.releaseGrant(uri)

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
