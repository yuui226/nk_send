package com.ztransfer.diagnostics

/** Release 空实现：正式包不记录缩略图诊断数据。 */
@Suppress("UNUSED_PARAMETER")
object ThumbnailDiagnostics {
    const val enabled: Boolean = false

    fun beginSession(description: String) = Unit
    fun note(message: String, failure: Boolean = false) = Unit
    fun snapshot(): String = ""
    fun clear() = Unit
}
