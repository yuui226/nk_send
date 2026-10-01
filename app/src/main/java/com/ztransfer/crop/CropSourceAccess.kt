package com.ztransfer.crop

import android.content.ContentResolver
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/**
 * Keep a provider's regular-file descriptor alive while native crop opens its proc alias.
 * The alias opens an independent cursor; header/EXIF reads cannot move the native input cursor.
 * Pipes and providers that reject descriptor aliases use the bounded-buffer copy fallback.
 * Must run on the generation worker, never on the UI or download worker.
 */
internal suspend fun <T> withCropSource(
    resolver: ContentResolver,
    uri: Uri,
    fallback: File,
    consume: suspend (File) -> T,
): T {
    val context = currentCoroutineContext()
    context.ensureActive()
    var descriptor: ParcelFileDescriptor? = null
    val direct = try {
        descriptor = resolver.openFileDescriptor(uri, "r")
        descriptor?.let { opened ->
            val stat = Os.fstat(opened.fileDescriptor)
            if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_size <= 0L) null
            else File("/proc/self/fd/${opened.fd}").takeIf { alias ->
                // Check that reopening is permitted before handing ownership to the crop code.
                alias.inputStream().use { it.read() >= 0 }
            }
        }
    } catch (cancelled: CancellationException) {
        descriptor?.close()
        throw cancelled
    } catch (_: Exception) { null }
    if (direct != null) {
        return descriptor.use {
            context.ensureActive()
            consume(direct)
        }
    }
    descriptor?.close()
    context.ensureActive()
    try {
        resolver.openInputStream(uri)?.use { input ->
            fallback.outputStream().buffered().use { output ->
                val buffer = ByteArray(256 * 1024)
                while (true) {
                    context.ensureActive()
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (count > 0) output.write(buffer, 0, count)
                }
            }
        } ?: throw IOException("Cannot open saved original")
        context.ensureActive()
        return consume(fallback)
    } finally { fallback.delete() }
}
