package com.ztransfer.diagnostics

/** Release 空实现：正式包不记录生成诊断数据。 */
@Suppress("UNUSED_PARAMETER")
object PhotoGenerationProbe {
    const val enabled: Boolean = false
    const val NO_SESSION: Long = -1L

    fun begin(sourceName: String, configuration: String): Long = NO_SESSION
    fun stage(sessionId: Long, name: String, durationMs: Long, detail: String = "") = Unit
    fun finish(sessionId: Long, outcome: String, totalMs: Long) = Unit
    fun note(category: String, message: String) = Unit
}
