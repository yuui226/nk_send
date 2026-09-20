package com.ztransfer.ui.screen

import com.ztransfer.protocol.RcParam

/** Keep failures and mode transitions, without recording every successful live-view frame. */
internal fun isRemoteDiagnosticLine(line: String): Boolean {
    val lower = line.lowercase()
    return line.startsWith("!!") || listOf(
        "diagnostic", "capability", "selected=", " write ", "control mode",
        "controlmode", "applicationmode", "liveview", "deviceready", "probe complete"
    ).any { it in lower }
}

/** Preserve the original baseline as well as the latest outcome; bound clipboard/prefs size. */
internal fun appendRemoteDiagnosticLine(lines: MutableList<String>, line: String) {
    lines.add(if (line.length > 2_000) line.take(1_970) + " [line truncated]" else line)
    while (lines.size > 300 || lines.sumOf { it.length + 1 } > 96_000) {
        // The first 40 entries hold identity, the request and the baseline descriptors.
        lines.removeAt(40)
        if (lines.getOrNull(40) != OMITTED) lines.add(40, OMITTED)
        if (lines.size > 41) lines.removeAt(41)
    }
}

private const val OMITTED = "[diagnostic: older middle entries omitted; baseline and latest entries retained]"

internal fun canTryRemoteShutter(param: RcParam?): Boolean =
    param?.writable == true && param.values.any { it != param.current }
