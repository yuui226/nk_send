package com.ztransfer.diagnostics

import com.ztransfer.protocol.NikonCamera

/** 文件顺序问题已确认；保留空 API 以免诊断移除触碰稳定的相机枚举链路。 */
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
        files: List<NikonCamera.FileInfo>,
        elapsedMs: Long,
    ) = Unit
    fun beginThumbnail(handle: Int, lane: String): Int = -1
    fun finishThumbnail(sequence: Int, outcome: String, byteCount: Int?) = Unit
    fun finishScan(outcome: String) = Unit
    fun addNote(message: String) = Unit
}
