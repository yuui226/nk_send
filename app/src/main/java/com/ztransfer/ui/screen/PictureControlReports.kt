package com.ztransfer.ui.screen

import java.io.File

/** Each run gets its own append-only file; a cancelled run cannot overwrite a newer one. */
internal object PictureControlReports {
    enum class Kind(val fileLabel: String) { OVERVIEW("overview"), OPERATION("operation") }
    data class Ticket(val kind: Kind, val generation: Long)

    /** Retain at most one report of each kind; reads cannot erase a failed operation. */
    class History {
        private val generations = mutableMapOf<Kind, Long>()
        private val reports = mutableMapOf<Kind, String>()

        fun begin(kind: Kind): Ticket = Ticket(kind, (generations[kind] ?: 0L) + 1).also {
            generations[kind] = it.generation
        }

        fun finish(ticket: Ticket, text: String) {
            if (generations[ticket.kind] == ticket.generation && text.isNotBlank()) {
                reports[ticket.kind] = text
            }
        }

        fun restore(saved: Map<Kind, String>) {
            saved.forEach { (kind, text) ->
                if (kind !in generations && text.isNotBlank()) reports[kind] = text
            }
        }

        fun text(): String = listOfNotNull(reports[Kind.OPERATION], reports[Kind.OVERVIEW])
            .joinToString("\n\n")
    }

    /** Create/append on IO; the in-memory report remains shareable if saving fails. */
    class Journal(filesDir: File, kind: Kind) {
        private val text = StringBuilder()
        var saveFailed = false
            private set
        private val file = try { create(filesDir, kind) }
            catch (_: Exception) { saveFailed = true; null }

        fun append(line: String) {
            text.appendLine(line)
            try { file?.appendText(line + "\n", Charsets.UTF_8) }
            catch (_: Exception) { saveFailed = true }
        }

        fun report(): String = text.toString()
    }

    private fun directory(filesDir: File) = File(filesDir, "picture_control_reports").apply {
        check(isDirectory || mkdirs()) { "Cannot create Picture Control report directory" }
    }

    private fun create(filesDir: File, kind: Kind): File = File.createTempFile(
        "PictureControl-${System.currentTimeMillis()}-${kind.fileLabel}-", ".txt", directory(filesDir))

    fun latest(filesDir: File): Map<Kind, String> {
        val result = mutableMapOf<Kind, String>()
        val files = directory(filesDir).listFiles().orEmpty()
            .filter { it.name.startsWith("PictureControl-") && it.extension == "txt" && it.length() > 0 }
            .sortedByDescending { it.name }
        for (file in files) {
            val text = runCatching { file.readText(Charsets.UTF_8) }.getOrNull()?.takeIf(String::isNotBlank) ?: continue
            val kind = when {
                "-overview-" in file.name || text.startsWith("Picture Control overview ") -> Kind.OVERVIEW
                else -> Kind.OPERATION // Older files contain operation/probe reports only.
            }
            result.putIfAbsent(kind, text)
            if (result.size == Kind.entries.size) break
        }
        return result
    }

    // A share URI always refers to an immutable snapshot, including after another probe starts.
    fun shareSnapshot(filesDir: File, report: String): File = File.createTempFile(
        "Shared-PictureControl-", ".txt", directory(filesDir)).apply { writeText(report, Charsets.UTF_8) }
}
