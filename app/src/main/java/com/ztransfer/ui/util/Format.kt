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

/** 人类可读的耗时（<60s 显示 "8.4s"，否则 "2m05s"）。单位符号通用，与 MB/s 同样不进 i18n。 */
fun formatDuration(ms: Long): String {
    if (ms < 0) return "0.0s"
    val totalSec = ms / 1000.0
    return if (totalSec < 60) {
        String.format(Locale.US, "%.1fs", totalSec)
    } else {
        val m = ms / 60000
        val s = (ms % 60000) / 1000
        String.format(Locale.US, "%dm%02ds", m, s)
    }
}
