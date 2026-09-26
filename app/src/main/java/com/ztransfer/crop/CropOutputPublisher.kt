package com.ztransfer.crop

import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException

/** Publish only completed JPEGs. Rename-less providers receive a verified copy with rollback. */
internal suspend fun publishCropOutput(
    resolver: ContentResolver,
    source: File,
    parent: Uri,
    name: String,
    temporaryName: String,
): Uri = withContext(Dispatchers.IO) {
    var temporary: Uri? = null
    var fallback: Uri? = null
    var published = false
    try {
        require(source.isFile && source.length() > 0)
        temporary = DocumentsContract.createDocument(resolver, parent, "image/jpeg", temporaryName)
            ?: throw IOException("Cannot create crop output")
        source.inputStream().use { input ->
            val output = resolver.openOutputStream(checkNotNull(temporary), "w")
                ?: throw IOException("Cannot open crop output")
            output.buffered(1024 * 1024).use { sink ->
                if (input.copyTo(sink) != source.length()) throw IOException("Incomplete crop output")
            }
        }
        currentCoroutineContext().ensureActive()
        val renamed = try {
            DocumentsContract.renameDocument(resolver, checkNotNull(temporary), name)
        } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
        catch (_: Exception) { null }
        if (renamed != null) {
            temporary = null
            published = true
            return@withContext renamed
        }
        currentCoroutineContext().ensureActive()
        fallback = DocumentsContract.createDocument(resolver, parent, "image/jpeg", name)
            ?: throw IOException("Cannot create crop output")
        resolver.openInputStream(checkNotNull(temporary))?.use { input ->
            val output = resolver.openOutputStream(checkNotNull(fallback), "w")
                ?: throw IOException("Cannot open crop output")
            output.buffered(1024 * 1024).use { sink ->
                val buffer = ByteArray(256 * 1024)
                var written = 0L
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val count = input.read(buffer)
                    if (count < 0) break
                    sink.write(buffer, 0, count)
                    written += count
                }
                if (written != source.length()) throw IOException("Incomplete crop output")
            }
        } ?: throw IOException("Cannot reopen crop output")
        published = true
        checkNotNull(fallback)
    } finally {
        withContext(NonCancellable) {
            temporary?.let { runCatching { DocumentsContract.deleteDocument(resolver,it) } }
            if (!published) fallback?.let { runCatching { DocumentsContract.deleteDocument(resolver,it) } }
        }
    }
}
