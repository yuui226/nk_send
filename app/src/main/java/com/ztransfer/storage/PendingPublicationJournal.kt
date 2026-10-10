package com.ztransfer.storage

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

/**
 * Only Harmony publications use this journal. Record the provider URI before writing any
 * media bytes; a same-size document must not count as an original until verification passes.
 * A failed delete retains the record, including across process death. Never recover by name:
 * providers can rename on creation, and another file with that name must not be deleted.
 * All methods that touch disk are called on IO. The snapshot is safe for directory scans.
 */
internal class PendingPublicationJournal(private val directory: File) {
    data class Entry(val id: String, val uri: String)

    private val entries = LinkedHashMap<String, Entry>()
    private var loaded = false

    @Synchronized
    fun pending(): List<Entry> {
        load()
        return entries.values.toList()
    }

    @Synchronized
    fun begin(uri: String): Entry {
        require(uri.isNotBlank() && '\n' !in uri && '\r' !in uri)
        load()
        val entry = Entry(UUID.randomUUID().toString(), uri)
        persist(entry, verified = false)
        entries[entry.id] = entry
        return entry
    }

    @Synchronized
    fun verified(entry: Entry) {
        // Persist the verdict before unlinking: even if unlink fails, the next launch
        // must not delete an already validated original.
        persist(entry, verified = true)
        entries.remove(entry.id)
        file(entry.id).delete()
    }

    @Synchronized
    fun removed(entry: Entry) {
        // Called only after the provider confirms deletion (or absence).
        verified(entry)
    }

    private fun load() {
        if (loaded) return
        directory.listFiles()?.filter { it.name.endsWith(".pending") }?.forEach { marker ->
            val lines = marker.readLines(Charsets.UTF_8)
            check(lines.size == 2 && lines[0] in setOf("pending", "verified") && lines[1].isNotBlank()) {
                "Invalid pending publication journal: ${marker.name}"
            }
            if (lines[0] == "pending") {
                val entry = Entry(marker.name.removeSuffix(".pending"), lines[1])
                entries[entry.id] = entry
            } else {
                marker.delete()
            }
        }
        loaded = true
    }

    private fun file(id: String) = File(directory, "$id.pending")

    private fun persist(entry: Entry, verified: Boolean) {
        check(directory.isDirectory || directory.mkdirs()) { "Cannot create publication journal directory" }
        val target = file(entry.id)
        val temporary = File(directory, "${entry.id}.tmp")
        try {
            FileOutputStream(temporary).use { output ->
                output.write("${if (verified) "verified" else "pending"}\n${entry.uri}\n".toByteArray(Charsets.UTF_8))
                output.fd.sync()
            }
            try {
                Files.move(
                    temporary.toPath(), target.toPath(),
                    StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING,
                )
            } catch (_: java.nio.file.AtomicMoveNotSupportedException) {
                // Some Android filesystems do not expose atomic rename. The temporary
                // file still prevents a torn marker from being observed; replace it
                // with the normal provider-supported move as the compatibility fallback.
                Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
        } finally {
            temporary.delete()
        }
    }
}
