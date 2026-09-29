package com.ztransfer.protocol

private val RESUMABLE_VIDEO_EXTENSIONS = setOf("mov", "mp4", "nev", "avi")

/** Only videos keep partial output and request multiple camera data ranges. */
internal fun supportsVideoResume(fileName: String): Boolean =
    fileName.substringAfterLast('.', "").lowercase(java.util.Locale.ROOT) in RESUMABLE_VIDEO_EXTENSIONS
