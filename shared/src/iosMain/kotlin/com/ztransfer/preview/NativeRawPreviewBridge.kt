package com.ztransfer.preview

import kotlinx.cinterop.*
import platform.Foundation.NSData
import platform.posix.memcpy

/** Only the bounded index prefix crosses as a bulk copy; candidate bodies stay in Swift. */
@OptIn(ExperimentalForeignApi::class)
object NativeRawPreviewBridge {
    fun candidates(data: NSData): List<NefPreviewReference> {
        if (data.length == 0uL || data.length > LocalRawPreviewPolicy.indexPrefixBytes.toULong()) return emptyList()
        val source = data.bytes ?: return emptyList()
        val prefix = ByteArray(data.length.toInt())
        prefix.usePinned { memcpy(it.addressOf(0), source, data.length) }
        // Legacy corrupt TIFF offsets can throw. Never let a Kotlin parser exception escape ObjC.
        return try { LocalRawPreviewPolicy.candidates(prefix) } catch (_: Exception) { emptyList() }
    }

    fun isCompleteJpeg(data: NSData): Boolean {
        if (data.length < 4uL || data.length > Int.MAX_VALUE.toULong()) return false
        val bytes = data.bytes?.reinterpret<UByteVar>() ?: return false
        val size = data.length.toInt()
        return LocalRawPreviewPolicy.hasJpegEnvelope(
            size.toLong(), bytes[0].toInt(), bytes[1].toInt(), bytes[size - 2].toInt(), bytes[size - 1].toInt(),
        )
    }
}
