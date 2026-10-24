package com.ztransfer.diagnostics

/** Release 空实现：正式包不保存照片位置诊断记录。 */
@Suppress("UNUSED_PARAMETER")
object PhotoLocationDiagnostics {
    const val enabled: Boolean = false

    fun record(source: String, stage: String, detail: String) = Unit
    fun report(): String = ""
    fun clear() = Unit
}
