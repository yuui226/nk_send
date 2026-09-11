package com.ztransfer.diagnostics

import com.ztransfer.protocol.CameraFileInfo

/** Release 空实现：正式包没有文件顺序探测、日志状态或额外协议请求。 */
@Suppress("UNUSED_PARAMETER")
object FileOrderProbe {
    const val enabled: Boolean = false

    fun beginConnection(kind: String) = Unit
    fun recordCapabilities(
        manufacturer: String,
        model: String,
        deviceVersion: String,
        operations: Set<Int>,
    ) = Unit
    fun recordCapabilityFailure(message: String) = Unit
    fun beginScan(description: String) = Unit
    fun recordStorageIds(ids: List<Int>) = Unit
    fun recordRawHandles(storageId: Int, handles: List<Int>, elapsedMs: Long) = Unit
    fun recordScheduledHandles(handles: List<Int>) = Unit
    fun appendScheduledHandles(handles: List<Int>) = Unit
    fun recordObjectInfoBatch(
        requestedHandles: List<Int>,
        files: List<CameraFileInfo>,
        elapsedMs: Long,
    ) = Unit
    fun beginThumbnail(handle: Int, lane: String): Int = -1
    fun finishThumbnail(sequence: Int, outcome: String, byteCount: Int?) = Unit
    fun finishScan(outcome: String) = Unit
    fun addNote(message: String) = Unit
}
