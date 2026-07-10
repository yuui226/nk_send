package com.ztransfer.ui.util

import java.util.Locale

/** 人类可读的文件大小（B/KB/MB/GB）。 */
fun formatFileSize(bytes: Long): String = when {
    bytes < 1024 -> "$bytes B"
    bytes < 1024 * 1024 -> "${bytes / 1024} KB"
    bytes < 1024 * 1024 * 1024 -> String.format(Locale.US, "%.1f MB", bytes / (1024.0 * 1024.0))
    else -> String.format(Locale.US, "%.2f GB", bytes / (1024.0 * 1024.0 * 1024.0))
}

/** 人类可读的传输速度（B/s、KB/s、MB/s）。 */
fun formatSpeed(bytesPerSec: Long): String = when {
    bytesPerSec < 1024 -> "$bytesPerSec B/s"
    bytesPerSec < 1024 * 1024 -> String.format(Locale.US, "%.1f KB/s", bytesPerSec / 1024.0)
    else -> String.format(Locale.US, "%.1f MB/s", bytesPerSec / (1024.0 * 1024.0))
}
