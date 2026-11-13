package com.ztransfer.diagnostics

/** Release does not collect, allocate or publish STA timing reports. */
@Suppress("UNUSED_PARAMETER")
object StaConnectionDiagnostics {
    const val enabled = false
    const val NO_SESSION = -1L
    fun begin(): Long = NO_SESSION
    fun note(sessionId: Long, text: String) = Unit
    fun attempt(sessionId: Long, label: String, report: String) = Unit
    fun finish(sessionId: Long, outcome: String) = Unit
    fun clear() = Unit
    fun snapshot(): String = ""
}
