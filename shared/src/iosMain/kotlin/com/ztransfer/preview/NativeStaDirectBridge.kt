package com.ztransfer.preview

import com.ztransfer.protocol.*
import kotlinx.cinterop.*
import platform.Foundation.NSData
import platform.posix.memcpy

/** Bounded bulk-copy adapter. No Swift reimplementation of MPF/TIFF/MakerNote/name parsers. */
@OptIn(ExperimentalForeignApi::class)
object NativeStaDirectBridge {
    private fun bytes(data: NSData, limit: Int = 16 * 1024 * 1024): ByteArray? {
        if (data.length > limit.toULong()) return null
        if (data.length == 0uL) return ByteArray(0)
        val source = data.bytes ?: return null
        return ByteArray(data.length.toInt()).also { value ->
            value.usePinned { memcpy(it.addressOf(0), source, data.length) }
        }
    }
    fun loadDates(model: NativeStaDirectMetadata, data: NSData) { bytes(data)?.let(model::loadDates) }
    fun loadNames(model: NativeStaDirectMetadata, data: NSData) { bytes(data)?.let(model::loadNames) }
    fun loadName(model: NativeStaDirectMetadata, handle: Int, data: NSData): String? =
        bytes(data, 64 * 1024)?.let { model.loadName(handle, it) }
    fun headerInfo(model: NativeStaDirectMetadata, handle: Int, size: Long, data: NSData,
                   exifDate: String?, storageId: Int): PtpObjectInfo? =
        try { bytes(data, 128 * 1024)?.let { model.headerInfo(handle, size, it, exifDate, storageId) } }
        catch (_: Exception) { null }
    fun mediaExtension(data: NSData): String? = bytes(data, 128 * 1024)?.let(::staDirectObjectExtension)
    fun videoCaptureSeconds(data: NSData): Long? = bytes(data)?.let(::staDirectVideoCaptureSeconds)
    fun exifSegment(data: NSData): NefPreviewReference? =
        bytes(data, 128 * 1024)?.let(::jpegExifSegmentRange)?.let {
            NefPreviewReference(it.first.toLong(), it.last - it.first + 1)
        }
    fun rawIndexed(data: NSData): List<NefPreviewReference> =
        try { bytes(data)?.let { parseNefHeaderMetadata(it).previews } ?: emptyList() }
        catch (_: Exception) { emptyList() }
    fun scannedJpeg(data: NSData): NefPreviewReference? =
        bytes(data)?.let(::largestEmbeddedJpegRange)
    fun rawThumbnailProbe(available: Long, previous: Int): StaDirectRawThumbnailProbePlan? =
        staDirectRawThumbnailProbePlan(available, previous)
    fun mpf(data: NSData, objectSize: Long): List<JpegMpfPreviewReference> =
        try { bytes(data, 128 * 1024)?.let { parseJpegMpfPreviews(it, objectSize) } ?: emptyList() }
        catch (_: Exception) { emptyList() }
}
