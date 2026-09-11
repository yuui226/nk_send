package com.ztransfer.preview

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import platform.Foundation.NSData
import platform.posix.memcpy

/** Per-read bulk copy, never one Swift/Kotlin call per byte. Reader budgets bound all requests. */
@OptIn(ExperimentalForeignApi::class)
object NativePreviewExifRationalBridge {
    fun bytes(data: NSData): ByteArray? {
        if (data.length > PreviewExifRationalReader.maximumReadBytes.toULong()) return null
        if (data.length == 0uL) return ByteArray(0)
        val source = data.bytes ?: return null
        return ByteArray(data.length.toInt()).also { bytes ->
            bytes.usePinned { memcpy(it.addressOf(0), source, data.length) }
        }
    }
    fun read(source: PreviewExifByteSource, size: Long): PreviewExifRationalValues =
        PreviewExifRationalReader.readMetadata(source, size, header = false)
    fun readHeader(source: PreviewExifByteSource, size: Long): PreviewExifRationalValues =
        PreviewExifRationalReader.readMetadata(source, size, header = true)
}
