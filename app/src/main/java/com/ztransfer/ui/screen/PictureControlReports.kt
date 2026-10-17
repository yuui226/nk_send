package com.ztransfer.ui.screen

import java.io.File

/** Each run gets its own append-only file; a cancelled run cannot overwrite a newer one. */
internal object PictureControlReports {
    private fun directory(filesDir: File) = File(filesDir, "picture_control_reports").apply {
        check(isDirectory || mkdirs()) { "Cannot create Picture Control report directory" }
    }

    fun create(filesDir: File): File = File.createTempFile(
        "PictureControl-${System.currentTimeMillis()}-", ".txt", directory(filesDir))

    fun latest(filesDir: File): String? = directory(filesDir).listFiles()
        ?.filter { it.name.startsWith("PictureControl-") && it.extension == "txt" && it.length() > 0 }
        ?.maxByOrNull { it.name }?.readText(Charsets.UTF_8)

    // A share URI always refers to an immutable snapshot, including after another probe starts.
    fun shareSnapshot(filesDir: File, report: String): File = File.createTempFile(
        "Shared-PictureControl-", ".txt", directory(filesDir)).apply { writeText(report, Charsets.UTF_8) }
}
