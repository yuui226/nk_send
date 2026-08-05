package com.ztransfer.filter

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException

private const val PHOTO_FILTER_DIRECTORY = "photo-filters"
private const val MAX_NP3_BYTES = 16 * 1024

data class PhotoFilterImportReport(
    val available: List<Np3PhotoFilter>,
    val imported: List<Np3PhotoFilter>,
    val duplicateCount: Int,
    val rejectedCount: Int,
)

object PhotoFilterStore {
    fun loadAll(context: Context): List<Np3PhotoFilter> {
        val directory = File(context.filesDir, PHOTO_FILTER_DIRECTORY)
        return directory.listFiles { file -> file.isFile && file.extension == "np3" }
            .orEmpty()
            .mapNotNull { file ->
                runCatching { Np3PhotoFilterParser.parse(file.readBytes()) }.getOrNull()
            }
            .distinctBy(Np3PhotoFilter::id)
            .sortedBy { it.name.lowercase() }
    }

    fun import(
        context: Context,
        resolver: ContentResolver,
        uris: List<Uri>,
    ): PhotoFilterImportReport {
        val directory = File(context.filesDir, PHOTO_FILTER_DIRECTORY).apply { mkdirs() }
        val existing = loadAll(context).associateBy(Np3PhotoFilter::id).toMutableMap()
        val imported = mutableListOf<Np3PhotoFilter>()
        var duplicates = 0
        var rejected = 0
        uris.distinct().forEach { uri ->
            val bytes = runCatching { readLimited(resolver, uri) }.getOrElse {
                rejected++
                return@forEach
            }
            val preset = runCatching { Np3PhotoFilterParser.parse(bytes) }.getOrElse {
                rejected++
                return@forEach
            }
            if (preset.id in existing) {
                duplicates++
                return@forEach
            }
            val destination = File(directory, "${preset.id}.np3")
            val temporary = File(directory, ".${preset.id}.tmp")
            val stored = runCatching {
                temporary.outputStream().buffered().use { it.write(bytes) }
                if (!temporary.renameTo(destination)) {
                    destination.outputStream().buffered().use { it.write(bytes) }
                    temporary.delete()
                }
                true
            }.getOrElse {
                temporary.delete()
                false
            }
            if (stored) {
                existing[preset.id] = preset
                imported += preset
            } else {
                rejected++
            }
        }
        return PhotoFilterImportReport(
            available = existing.values.sortedBy { it.name.lowercase() },
            imported = imported,
            duplicateCount = duplicates,
            rejectedCount = rejected,
        )
    }

    private fun readLimited(resolver: ContentResolver, uri: Uri): ByteArray {
        val input = resolver.openInputStream(uri) ?: throw IOException("Cannot open NP3")
        return input.buffered().use { stream ->
            val output = ByteArrayOutputStream(1024)
            val buffer = ByteArray(1024)
            var total = 0
            while (true) {
                val read = stream.read(buffer)
                if (read < 0) break
                total += read
                if (total > MAX_NP3_BYTES) throw IOException("NP3 is too large")
                output.write(buffer, 0, read)
            }
            output.toByteArray()
        }
    }
}
