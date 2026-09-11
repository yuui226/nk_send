package com.ztransfer.ui.util

import com.ztransfer.format.formatDurationText
import com.ztransfer.format.formatFileSizeText
import com.ztransfer.format.formatTransferSpeedText
import java.util.Locale

/** 人类可读的文件大小（B/KB/MB/GB）。 */
fun formatFileSize(bytes: Long): String = formatFileSizeText(bytes, ::renderUsFixedDecimal)

/** 人类可读的传输速度（B/s、KB/s、MB/s）。 */
fun formatSpeed(bytesPerSec: Long): String =
    formatTransferSpeedText(bytesPerSec, ::renderUsFixedDecimal)

/** 人类可读的耗时（<60s 显示 "8.4s"，否则 "2m05s"）。单位符号通用，与 MB/s 同样不进 i18n。 */
fun formatDuration(ms: Long): String = formatDurationText(ms, ::renderUsFixedDecimal)

private fun renderUsFixedDecimal(value: Double, fractionDigits: Int): String =
    String.format(Locale.US, "%.${fractionDigits}f", value)
