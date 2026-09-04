package com.ztransfer.protocol

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.media.MediaMetadataRetriever
import android.net.Network
import android.os.SystemClock
import androidx.exifinterface.media.ExifInterface
import com.ztransfer.BuildConfig
import com.ztransfer.R
import com.ztransfer.catalog.cameraThumbnailCacheIdentity
import com.ztransfer.catalog.selectNewestCameraFileHeadIndex
import com.ztransfer.connection.StaInitiatorIdentity
import com.ztransfer.connection.hasUsableStaAlbumStorage
import com.ztransfer.connection.isExpectedStaResponder
import com.ztransfer.connection.isStaPairingOnlyOperationSet
import com.ztransfer.connection.shouldForceStaProfilePairing
import com.ztransfer.diagnostics.FileOrderProbe
import com.ztransfer.diagnostics.PhotoGenerationProbe
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** Maximum JPEG prefix retained while a fresh file is streamed to disk for EXIF parsing. */
private const val EXIF_HEADER_CAPTURE_BYTES = 256 * 1024

/** 写入本地文件失败（非相机连接错误），用于区分"掉线"与"磁盘/存储"问题。 */
class OutputWriteException(message: String, cause: Throwable) : Exception(message, cause)

/** PTP/IP 已响应但相机明确拒绝初始化；区别于普通网络不可达。 */
class CameraRefusedException(message: String) : Exception(message)

/**
 * 多卡流式归并时选择下一条。每张卡自己的 head 已经是该卡当前最新文件；跨卡只比较
 * ObjectInfo 拍摄时间。日期缺失的 head 优先弹出，避免它挡住同卡后续所有正常文件。
 * 时间相同保持卡槽输入顺序稳定，不再拿不透明的 handle 数值打破平局。
 */
internal fun selectNewestFileHeadIndex(
    heads: List<CameraFileInfo?>,
): Int? = selectNewestCameraFileHeadIndex(heads)

/**
 * 续传无法进行：已有半成品，但本次下载走不了分块路径（相机不支持 GetPartialObjectEx，
 * 或 >4GB 文件拿不到真实大小无法对齐）。全量 GetObject 只能从 0 开始、会写坏已定位到
 * 续传偏移的输出流，故绝不静默降级——抛此异常让调用方删掉半成品、从头重下。
 */
class ResumeUnavailableException : Exception()

/**
 * 单命令通道的轻量调度器。普通命令仍直接使用 [mutex]；交互式大图/EXIF 在排队前
 * 登记，分块传输在每个完整 PTP 事务之间检查登记，让交互请求先取得下一段通道。
 */
internal class CameraIoGate(
    val mutex: Mutex = Mutex(),
) {
    private val interactiveWaiters = MutableStateFlow(0)
    private val activeDownloads = MutableStateFlow(0)

    suspend fun <T> withInteractivePriority(block: suspend () -> T): T {
        interactiveWaiters.update { it + 1 }
        try {
            return block()
        } finally {
            interactiveWaiters.update { it - 1 }
        }
    }

    suspend fun <T> withInteractive(block: suspend () -> T): T =
        withInteractivePriority { mutex.withLock { block() } }

    suspend fun <T> withTransferSlice(block: suspend () -> T): T {
        while (true) {
            interactiveWaiters.first { it == 0 }
            mutex.lock()
            if (interactiveWaiters.value == 0) {
                try {
                    return block()
                } finally {
                    mutex.unlock()
                }
            }
            mutex.unlock()
        }
    }

    /**
     * 登记一整个协议下载，而不是某一个分块。下载在块间释放 [mutex] 时仍保持登记，
     * 让只应在空闲期执行的连接探测不会误插入下一块之前。
     */
    suspend fun <T> withDownloadActivity(block: suspend () -> T): T {
        activeDownloads.update { it + 1 }
        try {
            return block()
        } finally {
            activeDownloads.update { (it - 1).coerceAtLeast(0) }
        }
    }

    /**
     * 只在没有协议下载时执行普通命令。锁外快速判断避免无意义排队；拿到锁后必须再次
     * 判断，封住“心跳先判断空闲、下载随后开始、心跳排到某个分块后面”的竞态窗口。
     */
    suspend fun <T> withIdleCommand(skippedValue: T, block: suspend () -> T): T {
        if (activeDownloads.value > 0) return skippedValue
        return mutex.withLock {
            if (activeDownloads.value > 0) skippedValue else block()
        }
    }
}

internal class PairingCompletedException : Exception("Nikon pairing completed; reconnect required")

internal class UnexpectedStaResponderException(actualResponderGuid: String?) :
    Exception("Unexpected Nikon STA responder: $actualResponderGuid")

internal const val PTPIP_IDENTITY_PREFERENCES = "ptpip_identity"
internal const val STA_PAIRING_MARKER_PREFIX = "sta_paired_"

/** PTP/IP Event payload: u16 code + u32 transactionId + optional u32 parameters. */
internal fun parsePtpIpEvent(payload: ByteArray?): Pair<Int, Long>? {
    val event = PtpIpProtocolCodec.decodeEvent(payload) ?: return null
    return event.code to event.firstParameter
}

/** File type fallback for paired STA sessions where Nikon denies ObjectInfo. */
internal fun staDirectObjectExtension(header: ByteArray): String = when {
    header.size >= 2 && header[0] == 0xFF.toByte() && header[1] == 0xD8.toByte() -> ".jpg"
    header.size >= 4 &&
        ((header[0] == 'I'.code.toByte() && header[1] == 'I'.code.toByte() &&
            header[2] == 0x2A.toByte() && header[3] == 0.toByte()) ||
            (header[0] == 'M'.code.toByte() && header[1] == 'M'.code.toByte() &&
                header[2] == 0.toByte() && header[3] == 0x2A.toByte())) -> ".nef"
    header.size >= 12 && header.copyOfRange(4, 8).contentEquals("ftyp".toByteArray()) -> {
        val brand = header.copyOfRange(8, 12).toString(Charsets.US_ASCII)
        if (brand == "qt  ") ".mov" else ".mp4"
    }
    else -> ".bin"
}

/** Converts EXIF `yyyy:MM:dd HH:mm:ss` into the PTP date form used by the existing UI. */
internal fun staDirectCaptureDate(exifDate: String?): String? {
    val digits = exifDate?.filter(Char::isDigit) ?: return null
    if (digits.length < 14) return null
    return digits.take(8) + "T" + digits.substring(8, 14)
}

/**
 * Builds a complete minimal JPEG containing only SOI + the EXIF APP1 segment + EOI.
 * Nikon's APP1 can be a few bytes larger than 64 KiB once JPEG framing is included, while the
 * original-file prefix is intentionally truncated. Feeding this envelope to ExifInterface avoids
 * making it parse an incomplete image scan.
 */
private fun jpegExifSegmentRange(header: ByteArray): IntRange? {
    if (header.size < 10 || header[0] != 0xFF.toByte() || header[1] != 0xD8.toByte()) return null
    var offset = 2
    while (offset + 4 <= header.size) {
        val markerStart = offset
        if (header[offset] != 0xFF.toByte()) return null
        while (offset < header.size && header[offset] == 0xFF.toByte()) offset++
        if (offset >= header.size) return null
        val marker = header[offset].toInt() and 0xFF
        offset++
        if (marker == 0xD9 || marker == 0xDA) return null
        if (marker == 0x01 || marker in 0xD0..0xD7) continue
        if (offset + 2 > header.size) return null
        val segmentLength =
            ((header[offset].toInt() and 0xFF) shl 8) or (header[offset + 1].toInt() and 0xFF)
        if (segmentLength < 2) return null
        val segmentEnd = offset + segmentLength
        if (segmentEnd > header.size) return null
        val payloadOffset = offset + 2
        val isExif = marker == 0xE1 && payloadOffset + 6 <= segmentEnd &&
            header[payloadOffset] == 'E'.code.toByte() &&
            header[payloadOffset + 1] == 'x'.code.toByte() &&
            header[payloadOffset + 2] == 'i'.code.toByte() &&
            header[payloadOffset + 3] == 'f'.code.toByte() &&
            header[payloadOffset + 4] == 0.toByte() &&
            header[payloadOffset + 5] == 0.toByte()
        if (isExif) {
            return markerStart until segmentEnd
        }
        offset = segmentEnd
    }
    return null
}

internal fun jpegExifEnvelope(header: ByteArray): ByteArray? {
    val segment = jpegExifSegmentRange(header) ?: return null
    val segmentBytes = segment.last - segment.first + 1
    return ByteArray(2 + segmentBytes + 2).also { envelope ->
        envelope[0] = 0xFF.toByte()
        envelope[1] = 0xD8.toByte()
        header.copyInto(
            envelope,
            destinationOffset = 2,
            startIndex = segment.first,
            endIndex = segment.last + 1,
        )
        envelope[envelope.lastIndex - 1] = 0xFF.toByte()
        envelope[envelope.lastIndex] = 0xD9.toByte()
    }
}

internal fun needsStaDirectJpegHeaderExpansion(
    prefix: ByteArray,
    maximumHeaderBytes: Int,
): Boolean = prefix.size < maximumHeaderBytes && jpegExifSegmentRange(prefix) == null

/** Bounded JPEG marker audit used to decide whether an independent MPF preview really exists. */
internal fun jpegContainerDiagnostics(bytes: ByteArray): String {
    if (bytes.size < 4 || bytes[0] != 0xFF.toByte() || bytes[1] != 0xD8.toByte()) {
        return "not-jpeg"
    }
    val segments = ArrayList<String>(8)
    var offset = 2
    while (offset + 1 < bytes.size && segments.size < 12) {
        while (offset < bytes.size && bytes[offset] == 0xFF.toByte()) offset++
        if (offset >= bytes.size) break
        val marker = bytes[offset].toInt() and 0xFF
        offset++
        if (marker == 0xD9) {
            segments += "EOI"
            break
        }
        if (marker == 0xDA) {
            segments += "SOS"
            break
        }
        if (marker == 0x01 || marker in 0xD0..0xD7) continue
        if (offset + 2 > bytes.size) {
            segments += "0x%02X:truncated".format(marker)
            break
        }
        val segmentLength = ((bytes[offset].toInt() and 0xFF) shl 8) or
            (bytes[offset + 1].toInt() and 0xFF)
        if (segmentLength < 2 || offset.toLong() + segmentLength > bytes.size.toLong()) {
            segments += "0x%02X:%d/incomplete".format(marker, segmentLength)
            break
        }
        val payloadOffset = offset + 2
        val payloadLength = segmentLength - 2
        val name = when (marker) {
            in 0xE0..0xEF -> "APP${marker - 0xE0}"
            0xDB -> "DQT"
            in 0xC0..0xCF -> "SOF/0x%02X".format(marker)
            else -> "0x%02X".format(marker)
        }
        val signature = when {
            marker == 0xE1 && payloadLength >= 6 &&
                bytes.copyOfRange(payloadOffset, payloadOffset + 6).contentEquals(
                    byteArrayOf('E'.code.toByte(), 'x'.code.toByte(), 'i'.code.toByte(),
                        'f'.code.toByte(), 0, 0),
                ) -> "Exif"
            marker == 0xE2 && payloadLength >= 4 &&
                bytes.copyOfRange(payloadOffset, payloadOffset + 4).contentEquals(
                    byteArrayOf('M'.code.toByte(), 'P'.code.toByte(), 'F'.code.toByte(), 0),
                ) -> "MPF"
            else -> null
        }
        segments += "$name:$segmentLength${signature?.let { "/$it" }.orEmpty()}"
        offset += segmentLength
    }
    return segments.joinToString(",").ifEmpty { "empty" }
}

internal data class JpegMpfPreviewReference(
    val offset: Long,
    val length: Int,
    val imageType: Int,
)

/**
 * Parses the MP Index IFD in a JPEG APP2 `MPF\0` segment. MP image offsets are relative to the
 * TIFF byte-order field at the start of the MP header; only independently stored large-thumbnail
 * JPEGs are returned. The primary image at offset 0 is deliberately excluded.
 */
internal fun parseJpegMpfPreviews(
    bytes: ByteArray,
    objectSize: Long = Long.MAX_VALUE,
): List<JpegMpfPreviewReference> {
    data class MpfSegment(val tiffBase: Int, val end: Int)

    fun findMpfSegment(): MpfSegment? {
        if (bytes.size < 4 || bytes[0] != 0xFF.toByte() || bytes[1] != 0xD8.toByte()) return null
        var offset = 2
        while (offset + 1 < bytes.size) {
            while (offset < bytes.size && bytes[offset] == 0xFF.toByte()) offset++
            if (offset >= bytes.size) return null
            val marker = bytes[offset].toInt() and 0xFF
            offset++
            if (marker == 0xD9 || marker == 0xDA) return null
            if (marker == 0x01 || marker in 0xD0..0xD7) continue
            if (offset + 2 > bytes.size) return null
            val segmentLength = ((bytes[offset].toInt() and 0xFF) shl 8) or
                (bytes[offset + 1].toInt() and 0xFF)
            if (segmentLength < 2 || offset.toLong() + segmentLength > bytes.size.toLong()) {
                return null
            }
            val payload = offset + 2
            if (marker == 0xE2 && segmentLength >= 14 &&
                bytes[payload] == 'M'.code.toByte() &&
                bytes[payload + 1] == 'P'.code.toByte() &&
                bytes[payload + 2] == 'F'.code.toByte() &&
                bytes[payload + 3] == 0.toByte()
            ) {
                return MpfSegment(tiffBase = payload + 4, end = offset + segmentLength)
            }
            offset += segmentLength
        }
        return null
    }

    val segment = findMpfSegment() ?: return emptyList()
    val littleEndian = when {
        bytes[segment.tiffBase] == 'I'.code.toByte() &&
            bytes[segment.tiffBase + 1] == 'I'.code.toByte() -> true
        bytes[segment.tiffBase] == 'M'.code.toByte() &&
            bytes[segment.tiffBase + 1] == 'M'.code.toByte() -> false
        else -> return emptyList()
    }

    fun u16(offset: Int): Int? {
        if (offset < segment.tiffBase || offset + 2 > segment.end) return null
        val a = bytes[offset].toInt() and 0xFF
        val b = bytes[offset + 1].toInt() and 0xFF
        return if (littleEndian) a or (b shl 8) else (a shl 8) or b
    }

    fun u32(offset: Int): Long? {
        if (offset < segment.tiffBase || offset + 4 > segment.end) return null
        var value = 0L
        if (littleEndian) {
            repeat(4) { index ->
                value = value or ((bytes[offset + index].toLong() and 0xFF) shl (index * 8))
            }
        } else {
            repeat(4) { index ->
                value = (value shl 8) or (bytes[offset + index].toLong() and 0xFF)
            }
        }
        return value
    }

    if (u16(segment.tiffBase + 2) != 42) return emptyList()
    val ifdOffset = u32(segment.tiffBase + 4) ?: return emptyList()
    val ifdStartLong = segment.tiffBase.toLong() + ifdOffset
    if (ifdStartLong !in segment.tiffBase.toLong() until segment.end.toLong()) return emptyList()
    val ifdStart = ifdStartLong.toInt()
    val entryCount = u16(ifdStart) ?: return emptyList()
    if (entryCount > 64 || ifdStart.toLong() + 2L + entryCount.toLong() * 12L > segment.end) {
        return emptyList()
    }

    var declaredImageCount: Int? = null
    var mpEntryOffset: Int? = null
    var mpEntryBytes = 0
    repeat(entryCount) { index ->
        val entry = ifdStart + 2 + index * 12
        val tag = u16(entry) ?: return@repeat
        val type = u16(entry + 2) ?: return@repeat
        val count = u32(entry + 4) ?: return@repeat
        when (tag) {
            0xB001 -> if (type == 4 && count == 1L) {
                declaredImageCount = u32(entry + 8)?.toInt()
            }
            0xB002 -> if (type == 7 && count in 16L..(16L * 64L) && count % 16L == 0L) {
                val relative = u32(entry + 8) ?: return@repeat
                val absolute = segment.tiffBase.toLong() + relative
                if (absolute >= segment.tiffBase && absolute + count <= segment.end) {
                    mpEntryOffset = absolute.toInt()
                    mpEntryBytes = count.toInt()
                }
            }
        }
    }

    val entriesStart = mpEntryOffset ?: return emptyList()
    val availableCount = mpEntryBytes / 16
    val imageCount = minOf(declaredImageCount ?: availableCount, availableCount, 64)
    val previews = ArrayList<JpegMpfPreviewReference>(imageCount)
    repeat(imageCount) { index ->
        val entry = entriesStart + index * 16
        val attributes = u32(entry) ?: return@repeat
        val length = u32(entry + 4) ?: return@repeat
        val relativeOffset = u32(entry + 8) ?: return@repeat
        val imageFormat = (attributes ushr 24) and 0x07
        val imageType = (attributes and 0x00FFFFFF).toInt()
        val absoluteOffset = segment.tiffBase.toLong() + relativeOffset
        if (imageFormat == 0L && imageType in 0x010001..0x010005 &&
            relativeOffset > 0L &&
            length in 4L..STA_DIRECT_MAX_EMBEDDED_PREVIEW_BYTES.toLong() &&
            absoluteOffset > 0L && absoluteOffset + length <= objectSize
        ) {
            previews += JpegMpfPreviewReference(
                offset = absoluteOffset,
                length = length.toInt(),
                imageType = imageType,
            )
        }
    }
    return previews.distinct().sortedWith(
        compareBy<JpegMpfPreviewReference> {
            when (it.imageType) {
                0x010002 -> 0 // exact FHD
                0x010003 -> 1 // 4K if FHD is absent
                0x010001 -> 2 // VGA is still better than the EXIF thumbnail
                else -> 3
            }
        }.thenBy(JpegMpfPreviewReference::length),
    )
}

/** Reads QuickTime/MP4 `mvhd.creation_time` (seconds since 1904-01-01, big-endian). */
internal fun staDirectVideoCaptureDate(bytes: ByteArray): String? {
    var index = 0
    while (index + 12 <= bytes.size) {
        if (bytes[index] == 'm'.code.toByte() &&
            bytes[index + 1] == 'v'.code.toByte() &&
            bytes[index + 2] == 'h'.code.toByte() &&
            bytes[index + 3] == 'd'.code.toByte()
        ) {
            val version = bytes[index + 4].toInt() and 0xFF
            val creationOffset = index + 8
            val byteCount = if (version == 0) 4 else if (version == 1) 8 else return null
            if (creationOffset + byteCount > bytes.size) return null
            var secondsSince1904 = 0L
            repeat(byteCount) { offset ->
                secondsSince1904 = (secondsSince1904 shl 8) or
                    (bytes[creationOffset + offset].toLong() and 0xFF)
            }
            val unixSeconds = secondsSince1904 - QUICKTIME_EPOCH_OFFSET_SECONDS
            if (unixSeconds <= 0L) return null
            return runCatching {
                STA_DIRECT_DATE_FORMATTER.format(Instant.ofEpochSecond(unixSeconds))
            }.getOrNull()
        }
        index++
    }
    return null
}

internal data class NefPreviewReference(val offset: Long, val length: Int)

internal data class StaDirectRawThumbnailProbePlan(
    val initialBytes: Int,
    val maximumBytes: Int,
)

internal fun staDirectRawThumbnailProbePlan(
    availableBytes: Long,
    previousThumbnailBytes: Int,
): StaDirectRawThumbnailProbePlan? {
    if (availableBytes <= 0L) return null
    val previous = previousThumbnailBytes.coerceAtLeast(0).toLong()
    val maximum = minOf(
        availableBytes,
        maxOf(192L * 1024, previous + 64L * 1024),
        Int.MAX_VALUE.toLong(),
    ).toInt()
    val initial = minOf(
        maximum.toLong(),
        maxOf(128L * 1024, previous + 16L * 1024),
    ).toInt()
    return StaDirectRawThumbnailProbePlan(initial, maximum)
}

/** Returns the exact range of the largest complete JPEG embedded in a bounded RAW prefix. */
internal fun largestEmbeddedJpegRange(
    bytes: ByteArray,
    validLength: Int = bytes.size,
): NefPreviewReference? {
    val limit = validLength.coerceIn(0, bytes.size)
    var bestStart = -1
    var bestEnd = -1
    var start = -1
    var index = 0
    while (index + 1 < limit) {
        val first = bytes[index].toInt() and 0xFF
        val second = bytes[index + 1].toInt() and 0xFF
        if (first == 0xFF && second == 0xD8) {
            start = index
            index += 2
            continue
        }
        if (start >= 0 && first == 0xFF && second == 0xD9) {
            val end = index + 2
            if (end - start > bestEnd - bestStart) {
                bestStart = start
                bestEnd = end
            }
            start = -1
            index += 2
            continue
        }
        index++
    }
    return if (bestStart >= 0) {
        NefPreviewReference(bestStart.toLong(), bestEnd - bestStart)
    } else {
        null
    }
}

/** Returns the largest complete JPEG embedded in a bounded RAW prefix. */
internal fun largestEmbeddedJpeg(bytes: ByteArray): ByteArray? =
    largestEmbeddedJpegRange(bytes)?.let { range ->
        bytes.copyOfRange(range.offset.toInt(), range.offset.toInt() + range.length)
    }

internal data class NefHeaderMetadata(
    val captureDate: String?,
    val previews: List<NefPreviewReference>,
)

/** Parses the bounded TIFF directory tree and returns exact embedded-JPEG ranges. */
internal fun parseNefHeaderMetadata(
    bytes: ByteArray,
    validLength: Int = bytes.size,
): NefHeaderMetadata {
    val limit = validLength.coerceIn(0, bytes.size)
    if (limit < 8) return NefHeaderMetadata(null, emptyList())
    val littleEndian = when {
        bytes[0] == 'I'.code.toByte() && bytes[1] == 'I'.code.toByte() -> true
        bytes[0] == 'M'.code.toByte() && bytes[1] == 'M'.code.toByte() -> false
        else -> return NefHeaderMetadata(null, emptyList())
    }

    fun u16(offset: Int): Int? {
        if (offset < 0 || offset + 2 > limit) return null
        val first = bytes[offset].toInt() and 0xFF
        val second = bytes[offset + 1].toInt() and 0xFF
        return if (littleEndian) first or (second shl 8) else (first shl 8) or second
    }
    fun u32(offset: Int): Long? {
        if (offset < 0 || offset + 4 > limit) return null
        var value = 0L
        if (littleEndian) {
            repeat(4) { index ->
                value = value or ((bytes[offset + index].toLong() and 0xFF) shl (index * 8))
            }
        } else {
            repeat(4) { index ->
                value = (value shl 8) or (bytes[offset + index].toLong() and 0xFF)
            }
        }
        return value
    }
    if (u16(2) != 42) return NefHeaderMetadata(null, emptyList())

    val previews = ArrayList<NefPreviewReference>()
    val visited = HashSet<Int>()
    var bestDate: Pair<Int, String>? = null

    fun typeSize(type: Int): Int = when (type) {
        1, 2, 7 -> 1
        3 -> 2
        4, 9 -> 4
        5, 10 -> 8
        else -> 0
    }

    fun valueOffset(entryOffset: Int, type: Int, count: Long): Int? {
        val unit = typeSize(type)
        if (unit == 0 || count <= 0 || count > Int.MAX_VALUE / unit) return null
        val byteCount = count.toInt() * unit
        return if (byteCount <= 4) entryOffset + 8 else u32(entryOffset + 8)?.toInt()
    }

    fun numericValues(entryOffset: Int, type: Int, count: Long): List<Long> {
        if (type != 3 && type != 4) return emptyList()
        val start = valueOffset(entryOffset, type, count) ?: return emptyList()
        val step = if (type == 3) 2 else 4
        if (count > 64 || start < 0 || start + count * step > limit) return emptyList()
        return (0 until count.toInt()).mapNotNull { index ->
            if (type == 3) u16(start + index * step)?.toLong() else u32(start + index * step)
        }
    }

    fun asciiValue(entryOffset: Int, type: Int, count: Long): String? {
        if (type != 2 || count <= 1 || count > 128) return null
        val start = valueOffset(entryOffset, type, count) ?: return null
        val length = count.toInt()
        if (start < 0 || start + length > limit) return null
        return bytes.copyOfRange(start, start + length)
            .toString(Charsets.US_ASCII)
            .trimEnd('\u0000', ' ')
            .takeIf(String::isNotBlank)
    }

    fun parseIfd(ifdOffset: Int, depth: Int) {
        if (depth > 8 || ifdOffset < 8 || !visited.add(ifdOffset)) return
        val count = u16(ifdOffset) ?: return
        if (count > 512) return
        val entriesStart = ifdOffset + 2
        if (entriesStart + count * 12 + 4 > limit) return

        var jpegOffsets = emptyList<Long>()
        var jpegLengths = emptyList<Long>()
        var stripOffsets = emptyList<Long>()
        var stripLengths = emptyList<Long>()
        var compression: Long? = null
        val childIfds = ArrayList<Int>()

        repeat(count) { index ->
            val entry = entriesStart + index * 12
            val tag = u16(entry) ?: return@repeat
            val type = u16(entry + 2) ?: return@repeat
            val valueCount = u32(entry + 4) ?: return@repeat
            val values = numericValues(entry, type, valueCount)
            when (tag) {
                0x0103 -> compression = values.firstOrNull()
                0x0111 -> stripOffsets = values
                0x0117 -> stripLengths = values
                0x014A, 0x8769 -> values.mapTo(childIfds) { it.toInt() }
                0x0201 -> jpegOffsets = values
                0x0202 -> jpegLengths = values
                0x0132, 0x9003, 0x9004 -> {
                    val priority = when (tag) {
                        0x9003 -> 3
                        0x9004 -> 2
                        else -> 1
                    }
                    asciiValue(entry, type, valueCount)?.let { raw ->
                        staDirectCaptureDate(raw)?.let { date ->
                            if (bestDate == null || priority > checkNotNull(bestDate).first) {
                                bestDate = priority to date
                            }
                        }
                    }
                }
            }
        }

        fun addRanges(offsets: List<Long>, lengths: List<Long>) {
            offsets.zip(lengths).forEach { (offset, length) ->
                if (offset > 0L && length in 4..STA_DIRECT_MAX_EMBEDDED_PREVIEW_BYTES.toLong()) {
                    previews += NefPreviewReference(offset, length.toInt())
                }
            }
        }
        addRanges(jpegOffsets, jpegLengths)
        if (compression == 6L) addRanges(stripOffsets, stripLengths)

        val nextIfdOffset = u32(entriesStart + count * 12)?.toInt() ?: 0
        if (nextIfdOffset > 0) childIfds += nextIfdOffset
        childIfds.forEach { child -> parseIfd(child, depth + 1) }
    }

    parseIfd(u32(4)?.toInt() ?: return NefHeaderMetadata(null, emptyList()), 0)
    return NefHeaderMetadata(
        captureDate = bestDate?.second,
        previews = previews.distinct().sortedByDescending(NefPreviewReference::length),
    )
}

private const val QUICKTIME_EPOCH_OFFSET_SECONDS = 2_082_844_800L
private const val STA_DIRECT_MAX_EMBEDDED_PREVIEW_BYTES = 16 * 1024 * 1024
private val STA_DIRECT_DATE_FORMATTER: DateTimeFormatter =
    DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss").withZone(ZoneId.systemDefault())

class NikonCamera(private val context: Context) {
    private var cmdSocket: Socket? = null
    private var evtSocket: Socket? = null
    private var cmdInput: java.io.InputStream? = null
    private var evtInput: java.io.InputStream? = null
    private var cmdOutput: OutputStream? = null
    private var usbPtp: UsbPtpConnection? = null
    private var connectedUsbManager: UsbManager? = null
    private var connectedUsbDevice: UsbDevice? = null
    private var tid = 0
    private val cmdReader = PacketReader(context)
    private val evtReader = PacketReader(context)
    private var evtThread: Thread? = null
    private val ptpIpEventChannel = Channel<Pair<Int, Long>>(capacity = 64)
    internal val ptpIpEvents: Flow<Pair<Int, Long>> = ptpIpEventChannel.receiveAsFlow()
    private val staDiagnosticLines = ArrayList<String>()
    internal val staDiagnosticReport: String
        get() = staDiagnosticLines.joinToString("\n")
    @Volatile internal var staAlbumAccessValidated = false
        private set
    @Volatile internal var staStorageProbeReached = false
        private set
    private var staEmptyObjectListObserved = false
    private var staObjectHandlesObserved = false
    /** ObjectInfo/GetThumb are denied, but size and partial original reads were verified. */
    @Volatile internal var staDirectObjectReadValidated = false
        private set
    private val staDirectMetadataDiagnostics = java.util.concurrent.ConcurrentHashMap<String, String>()
    internal val staDirectMetadataDiagnosticReports: List<String>
        get() = staDirectMetadataDiagnostics.toSortedMap().values.toList()
    // Encoded thumbnail bytes use a bounded LRU rather than a one-shot handoff. A visible cell can
    // be cancelled after camera IO but before disk write/decode; retaining recent bytes lets its
    // replacement finish locally instead of downloading the same RAW preview again.
    private val staDirectThumbnails = LinkedHashMap<Int, ByteArray>(16, 0.75f, true)
    private var staDirectThumbnailBytes = 0
    private val staDirectNoThumbnail = HashSet<Int>()
    private val staDirectFiles = HashMap<Int, CameraFileInfo>()
    private val staDirectJpegMpfPreviews = HashMap<Int, List<JpegMpfPreviewReference>>()
    private val staDirectRawPreviews = HashMap<Int, List<NefPreviewReference>>()
    // Same-camera NEFs usually place their grid JPEG at a stable offset. This session-only hint is
    // always JPEG-validated and falls back to the full prefix parser on the first mismatch.
    private var staDirectRawThumbnailHint: NefPreviewReference? = null
    // A scan-only thumbnail is not proof that the RAW's largest preview was found. Keep indexed
    // IFD references separate so full-screen preview never mistakes the first small JPEG for FHD.
    private val staDirectRawIndexedPreviews = HashSet<Int>()
    private val staDirectOriginalFileNames = HashMap<Int, String>()
    private val staDirectCaptureDates = HashMap<Int, String>()
    // 最近读取的少量文件前缀同时服务 MPF、EXIF、RAW 索引与缩略图；每项最多 512 KiB、
    // 总共 4 项，避免冷缓存扫描把整卡数据留在堆中。所有访问都在同一 PTP IO gate 内串行。
    private val staDirectRecentHeaders = LinkedHashMap<Int, ByteArray>(4, 0.75f, true)
    private var staDirectFileNumberAnchor: NikonFileNumberAnchor? = null
    // A dual-card body may maintain independent object-handle sequences per slot. A single anchor
    // inferred from card 1 must never be used to fabricate card 2's filename.
    private val staDirectFileNumberAnchorsByStorage = HashMap<Int, NikonFileNumberAnchor>()
    private val staDirectEmbeddedFileNameAvailable = HashMap<String, Boolean>()
    private var staDirectFileNameListAttempted = false
    private var staDirectFileNameValueSupported: Boolean? = null
    private var staDirectObjectsMetadataAttempted = false
    // internal 而非 private:遥控实验(RemoteLab.kt)以扩展函数复用同一互斥与收发原语,
    // 保证实验命令与传输/缩略图/心跳严格串行,不引入第二条 IO 路径。
    private val ioGate = CameraIoGate()
    internal val ioMutex: Mutex
        get() = ioGate.mutex
    // 一次自动对焦由多条独立 PTP 事务组成。对焦流程和普通遥控命令仍须严格串行，
    // 只有 Live View 取帧绕过此锁；因此不会为了释放 ioMutex 引入参数/拍摄命令穿插。
    internal val focusMutex = Mutex()
    // 会话是否已 OpenSession 成功；用于决定 close() 是否需要发送 CloseSession，
    // 避免在握手中途失败时空等 CloseSession 响应（最长可达 soTimeout）。
    @Volatile private var sessionOpen = false
    // Nikon GetPartialObjectEx (0x9431) 支持探测：null=未探测, true=支持, false=不支持。
    // 仅首块明确返回 Operation_Not_Supported 时置 false 并回退全量；瞬时错误不熔断。
    // 标准 PTP 0x101B 在 Nikon 机身上不被识别，须用此专有操作码。
    @Volatile private var partialObjectSupported: Boolean? = null
    // FHD 预览(0x920F)支持探测：null=未知, true=支持, false=明确不支持。
    // 只有标准 Operation_Not_Supported 才能整会话熔断；DeviceBusy 等暂态响应不得污染
    // 能力状态。一次成功后保持 true，避免后续单个 handle 的异常推翻已验证能力。
    // 每次 connect 新建 NikonCamera 实例，故换相机自动重新探测。仅 ioMutex 内访问。
    @Volatile private var fhdSupported: Boolean? = null
    // Paired STA uses an independent, read-only preview capability probe. Keeping these separate
    // ensures the established AP FHD latch and request behavior remain byte-for-byte unchanged.
    private var staFhdPictureSupported: Boolean? = null
    private var staLargeThumbSupported: Boolean? = null
    // STA 握手会用 GetStorageIDs 验证已经进入浏览能力集；把结果交给首次文件扫描消费，
    // 避免紧接着重复同一条命令触发部分固件的状态异常。
    private var prefetchedStorageIds: List<Int>? = null
    private data class PrefetchedStaObjectHandles(
        val queryStorageId: Int,
        val handles: List<Int>,
    )
    // Album validation already enumerates every handle. Single-storage sessions can hand that
    // exact result to the first catalog scan instead of immediately repeating GetObjectHandles.
    private var prefetchedStaObjectHandles: PrefetchedStaObjectHandles? = null
    // 遥控监看的取帧操作码：首次取帧从 DeviceInfo 解析并缓存。
    // 新机优先 0x9428（带 Display Information Data），不支持时回退 0x9203。
    // 每次连接都会新建 NikonCamera，因此不会把上一台机身的判断带进新会话。
    @Volatile internal var liveViewImageOperation: Int? = null
    // StartLiveView 后最后一次 DeviceReady 轮询完成的时刻。USB 监看用它补足机身
    // 传感器/编码器的启动预热窗口；即使页面先读取参数再接管已开启的 LV，也只等待
    // 尚未覆盖的那部分时间，不会重复写死一整段延迟。
    @Volatile internal var liveViewReadyAtElapsedMs = 0L
    // Nikon 主体追踪操作码（StartTracking/EndTracking）的会话级能力与生命周期。
    // null=尚未实际尝试，false=明确返回 Operation_Not_Supported；瞬时错误不熔断。
    // 两个字段只在 focusMutex 内读写；实际 Start/End 命令再按 focusMutex -> ioMutex 串行。
    internal var subjectTrackingSupported: Boolean? = null
    internal var subjectTrackingActive = false
    // 增强取帧偶发空/坏帧不能等同于“不支持”；连续两次才降级，成功即清零。
    // 仅在 ioMutex 内访问。
    internal var liveViewEnhancedFailureCount = 0
    // 远程录像兼容模式的成对记账放在连接对象上，而不是 Compose 页面里：
    // 横竖屏重建或离开后重进监看页时仍能正确停止录像并恢复相机状态；
    // 断线会创建新的 NikonCamera，自然不会把旧连接的记账带过去。
    @Volatile internal var remoteMovieApplicationPropSet = false
    @Volatile internal var remoteMovieApplicationOpSet = false
    // USB 录像期间持有的尼康完整远控模式（0x90C2）。开录前设 1，停录回待机时
    // 成对清 0；放在连接对象上可跨横竖屏重建记账，断线换实例则自然清空。
    @Volatile internal var remoteControlModeSet = false
    /** Identity reported by PTP DeviceInfo for the current camera session. */
    @Volatile var deviceManufacturer: String? = null
        private set
    @Volatile var deviceModel: String? = null
        private set
    @Volatile internal var cachedDeviceInfo: LabDeviceInfo? = null
        private set
    @Volatile private var responderGuid: String? = null
    @Volatile private var usbDeviceSerial: String? = null
    /** Stable PTP/IP body identity returned by InitCommandAck; available before DeviceInfo. */
    internal val staResponderGuid: String?
        get() = responderGuid
    /** True only after this installation has received an OK Nikon pairing result for this body. */
    internal val staPairingConfirmed: Boolean
        get() = hasCompletedStaPairing()
    /**
     * 跨连接稳定的机身身份，用于隔离缩略图磁盘缓存。有效的 PTP DeviceInfo 序列号
     * 可统一同一机身的 Wi-Fi/USB 缓存；缺失或为占位值时再用当前链路的物理标识兜底。
     */
    val thumbnailCacheIdentity: String
        get() {
            val transportId = if (usbPtp != null) usbDeviceSerial else responderGuid
            return cameraThumbnailCacheIdentity(
                manufacturer = deviceManufacturer,
                model = deviceModel,
                reportedSerial = cachedDeviceInfo?.serial,
                fallbackPhysicalId = transportId,
            )
        }
    val connectionType: CameraConnectionType
        get() = if (usbPtp != null) CameraConnectionType.USB else CameraConnectionType.WIFI

    private fun cacheDeviceInfo(data: ByteArray): LabDeviceInfo =
        parseDeviceInfo(data).also { info ->
            cachedDeviceInfo = info
            deviceManufacturer = info.manufacturer.trim().takeIf(String::isNotEmpty)
            deviceModel = info.model.trim().takeIf(String::isNotEmpty)
        }

    companion object {
        const val TAG = "ZTransfer"
        // 命令/事件通道的常规读超时。
        const val SO_TIMEOUT_MS = 60_000
        private const val STA_HANDSHAKE_TIMEOUT_MS = 5_000
        private const val USB_CONNECT_TIMEOUT_MS = 5_000
        // 仅给 Android USB Host 释放接口留一个调度窗口。真机验证表明更长的固定等待
        // 不会改善首次取帧，反而让页面看起来冻结。
        internal const val USB_REMOTE_REOPEN_SETTLE_MS = 100L
        // TCP 连接超时：本地热点正常握手 <300ms；缩短它让"相机侧 PTP 服务还没就绪"的
        // 失败尝试更快结束、更快进入下一轮重试。
        const val CONNECT_TIMEOUT_MS = 3_000
        private const val NIKON_COMPATIBILITY_INIT = 0x941C
        private const val NIKON_CHANGE_APPLICATION_MODE = 0x9435
        private const val STA_SAMPLE_BYTES = 64 * 1024
        internal const val STA_DIRECT_CATALOG_HEADER_BYTES = 128 * 1024
        internal const val STA_DIRECT_JPEG_THUMBNAIL_PREFIX_BYTES = 68 * 1024
        private const val STA_DIRECT_VIDEO_TAIL_BYTES = 256 * 1024
        private const val STA_DIRECT_VIDEO_THUMBNAIL_PREFIX_BYTES = 8 * 1024 * 1024
        private const val STA_DIRECT_RECENT_PREFIX_BYTES = 512 * 1024
        private const val STA_DIRECT_RECENT_PREFIX_COUNT = 4
        private const val STA_DIRECT_THUMBNAIL_CACHE_BYTES = 4 * 1024 * 1024
        private const val STA_DIRECT_RAW_FHD_MIN_BYTES = 512 * 1024
        private const val STA_DIRECT_RAW_FHD_MIN_LONG_EDGE = 1_600
        private val STA_DIRECT_RAW_PROBE_PREFIX_BYTES = intArrayOf(
            240 * 1024,
            256 * 1024,
            512 * 1024,
            1024 * 1024,
            2 * 1024 * 1024,
            4 * 1024 * 1024,
            8 * 1024 * 1024,
            16 * 1024 * 1024,
        )
        private const val PAIRING_EVENT_TIMEOUT_MS = 8_000L
        // 取消下载的排空安全阀：已向相机发送 Cancel 包后，在途数据只剩 ≈TCP 窗口的数 MB，
        // 排空应秒级完成；若累计排空超过该预算仍没等到响应包，说明机型不支持 Cancel、
        // 还在发整个文件——此时才断开由心跳/看护自动重连（断开会让相机侧会话挂起甚至
        // 关 Wi-Fi，重连可达数十秒，"停止后重试卡很久"，所以只作为兜底而非首选）。
        const val CANCEL_DRAIN_BUDGET = 32L * 1024 * 1024
        // 排空期间的读超时：部分机型收到 Cancel 停发数据后并不回 CMD_RESPONSE，按常规
        // 60s 超时会抱着 ioMutex 白等一分钟——重试的首个下载全程被挡住，表现为
        // "停止后重试卡半天没速度"。静默 3s 即认定连接不可用，断开走自动重连。
        const val CANCEL_DRAIN_TIMEOUT_MS = 3_000
        // Wi-Fi 浏览模式的已知大小文件优先走 GetPartialObjectEx，以便在块间让路；USB 以及
        // 用户停留传输页时的无线传输，普通新文件走 GetObject，续传/大文件走 64MB 分块。
        // 每块仍是独立 PTP 事务，块间释放相机通道供当前 FHD / EXIF 使用。
        // 也是断点续传的检查点粒度；旧版本留下的 64MB 对齐半成品仍天然兼容。
        // internal: TransferViewModel 引用此值做续传偏移对齐。
        const val CHUNK_SIZE = TRANSFER_RESUME_CHUNK_SIZE
        const val HIGH_THROUGHPUT_FULL_OBJECT_THRESHOLD =
            TRANSFER_HIGH_THROUGHPUT_FULL_OBJECT_THRESHOLD
        /** USB and the visible transfer screen avoid repeated camera-side PartialObject setup. */
        const val HIGH_THROUGHPUT_CHUNK_SIZE = TRANSFER_HIGH_THROUGHPUT_CHUNK_SIZE
        const val LARGE_FILE_THRESHOLD = TRANSFER_LARGE_FILE_THRESHOLD
        const val LARGE_FILE_CHUNK_SIZE = TRANSFER_LARGE_FILE_CHUNK_SIZE
        private const val FHD_DEVICE_BUSY_RETRIES = 2
        private const val FHD_DEVICE_BUSY_RETRY_DELAY_MS = 160L
    }

    /** 仅 debug 构建输出协议日志，避免 release 包泄露 handle/size 并拖慢热路径。 */
    private inline fun log(message: () -> String) {
        if (BuildConfig.DEBUG) android.util.Log.d(TAG, message())
    }

    private fun nextTid(): Int {
        tid++
        return tid
    }

    suspend fun connect(
        ip: String = PtpConstants.CAMERA_IP,
        network: Network? = null
    ): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            if (FileOrderProbe.enabled) FileOrderProbe.beginConnection("PTP/IP")
            // 经 Wi-Fi Network 的 socketFactory 建 socket：相机热点没有互联网，系统验证失败后
            // 常把【默认网络】切回蜂窝数据——普通 Socket() 走默认路由，连 192.168.1.1 的包进蜂窝
            // 黑洞，每次尝试烧满连接超时，直到系统把默认网切回 Wi-Fi 才能成功（用户感知
            // "连上 Wi-Fi 后还要干等一阵"）。绑定到 Wi-Fi 网络后首次尝试即可达。
            fun newSocket(): Socket = network?.socketFactory?.createSocket() ?: Socket()
            cmdSocket = newSocket().apply {
                tcpNoDelay = true
                soTimeout = SO_TIMEOUT_MS
                // 显式加大接收缓冲，撑起 TCP 接收窗口（4MB 远大于本地 Wi-Fi 所需，不会成为瓶颈；
                // 在延迟稍高时也能避免小窗口拖慢吞吐）。必须在 connect 前设置才对窗口缩放生效。
                receiveBufferSize = 4 * 1024 * 1024
                connect(InetSocketAddress(ip, PtpConstants.PTP_PORT), CONNECT_TIMEOUT_MS)
            }
            // 用 BufferedInputStream 批量化 socket 读：每包 8 字节头 + 小数据段本会产生大量 read 系统调用，
            // 缓冲后合并为大块读，减少系统调用开销（大数据段仍会直读进目标缓冲，无额外拷贝）。
            cmdInput = java.io.BufferedInputStream(cmdSocket!!.getInputStream(), 64 * 1024)
            cmdOutput = cmdSocket!!.getOutputStream()

            cmdOutput!!.write(makeInitReq())
            cmdOutput!!.flush()

            val ack = cmdReader.readPacket(cmdInput!!)
            if (ack.type != PtpConstants.INIT_CMD_ACK) {
                // INIT_FAIL = 相机主动拒绝（如未配对/连接数已满），与协议错乱区分开提示。
                return@withContext Result.failure(
                    if (ack.type == PtpConstants.INIT_FAIL) CameraRefusedException(
                        context.getString(R.string.error_camera_refused)
                    )
                    else Exception(context.getString(R.string.error_handshake_bad_ack))
                )
            }

            val initAck = PtpIpProtocolCodec.decodeInitCommandAck(ack.payload)
                ?: return@withContext Result.failure(Exception(context.getString(R.string.error_handshake_empty)))
            val sessionId = initAck.connectionNumber
            initAck.responderGuidHex?.let { responderGuid = it }

            evtSocket = newSocket().apply {
                soTimeout = SO_TIMEOUT_MS
                connect(InetSocketAddress(ip, PtpConstants.PTP_PORT), CONNECT_TIMEOUT_MS)
            }
            evtInput = evtSocket!!.getInputStream()

            val evtInit = PtpIpProtocolCodec.encodeInitEventRequest(sessionId)
            evtSocket!!.getOutputStream().write(evtInit)
            evtSocket!!.getOutputStream().flush()

            val evtAck = evtReader.readPacket(evtInput!!)
            if (evtAck.type != PtpConstants.INIT_EVT_ACK) {
                return@withContext Result.failure(Exception(context.getString(R.string.error_event_handshake)))
            }

            sendCmd(PtpConstants.OPEN_SESSION, sessionId)
            val resp = recvResp()
            // 0x201E Session Already Open：App 异常退出后相机侧旧会话可能未清，
            // 视为会话已就绪继续使用，否则会陷入"反复重连直到相机自己超时"的循环。
            if (resp != PtpConstants.RESPONSE_OK && resp != PtpConstants.SESSION_ALREADY_OPEN) {
                return@withContext Result.failure(Exception(context.getString(R.string.error_open_session, PtpConstants.translateResponse(context, resp))))
            }
            sessionOpen = true

            // Read the identity once while establishing the session so every camera-backed UI can
            // use the real body model without inserting a later command into thumbnail/transfer IO.
            try {
                sendCmd(PtpConstants.GET_DEVICE_INFO)
                val (deviceInfoResp, deviceInfoData) = recvRespWithPayload()
                if (deviceInfoResp == PtpConstants.RESPONSE_OK && deviceInfoData != null) {
                    val info = cacheDeviceInfo(deviceInfoData)
                    if (FileOrderProbe.enabled) {
                        FileOrderProbe.recordCapabilities(
                            manufacturer = info.manufacturer,
                            model = info.model,
                            deviceVersion = info.deviceVersion,
                            operations = info.operations,
                        )
                    }
                } else if (FileOrderProbe.enabled) {
                    FileOrderProbe.recordCapabilityFailure(
                        "response=0x${deviceInfoResp.toString(16)} data=${deviceInfoData?.size ?: 0}B"
                    )
                }
            } catch (e: Exception) {
                if (FileOrderProbe.enabled) {
                    FileOrderProbe.recordCapabilityFailure(
                        "${e.javaClass.simpleName}: ${e.message.orEmpty()}"
                    )
                }
            }

            startEvtThread()

            Result.success(Unit)
        } catch (e: Exception) {
            close()
            Result.failure(e)
        }
    }

    /**
     * Explicit STA-only connection entry. This is intentionally separate from [connect] so the
     * established camera-hotspot handshake remains byte-for-byte and control-flow unchanged.
     */
    internal suspend fun connectSta(
        ip: String,
        localAddress: InetAddress? = null,
        identity: StaInitiatorIdentity = StaInitiatorIdentity.PAIRED_COMPUTER,
        expectedResponderGuid: String? = null,
        allowPairing: Boolean = true,
        exploreAlbumAccess: Boolean = false,
        forceProfilePairing: Boolean = false,
        onConnectingStarted: (() -> Unit)? = null,
        onPairingStarted: (() -> Unit)? = null,
    ): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            staAlbumAccessValidated = false
            staStorageProbeReached = false
            staEmptyObjectListObserved = false
            staObjectHandlesObserved = false
            staDirectObjectReadValidated = false
            staFhdPictureSupported = null
            staLargeThumbSupported = null
            staDirectMetadataDiagnostics.clear()
            staDirectThumbnails.clear()
            staDirectThumbnailBytes = 0
            staDirectNoThumbnail.clear()
            staDirectFiles.clear()
            staDirectJpegMpfPreviews.clear()
            staDirectRawPreviews.clear()
            staDirectRawThumbnailHint = null
            staDirectRawIndexedPreviews.clear()
            staDirectOriginalFileNames.clear()
            staDirectCaptureDates.clear()
            staDirectRecentHeaders.clear()
            staDirectFileNumberAnchor = null
            staDirectFileNumberAnchorsByStorage.clear()
            staDirectEmbeddedFileNameAvailable.clear()
            staDirectFileNameListAttempted = false
            staDirectFileNameValueSupported = null
            staDirectObjectsMetadataAttempted = false
            prefetchedStaObjectHandles = null
            staDiagnosticLines.clear()
            staDiagnosticLines += "identity=${identity.name}"
            if (FileOrderProbe.enabled) FileOrderProbe.beginConnection("PTP/IP STA")
            fun newSocket(): Socket = Socket().apply {
                // Discovery has already proved this interface can reach the candidate. Preserve
                // that route for the real handshake instead of letting Android choose another
                // private/VPN/cellular interface between the port probe and InitCommand.
                if (localAddress != null) bind(InetSocketAddress(localAddress, 0))
            }

            cmdSocket = newSocket().apply {
                tcpNoDelay = true
                soTimeout = STA_HANDSHAKE_TIMEOUT_MS
                receiveBufferSize = 4 * 1024 * 1024
                connect(InetSocketAddress(ip, PtpConstants.PTP_PORT), CONNECT_TIMEOUT_MS)
            }
            cmdInput = java.io.BufferedInputStream(cmdSocket!!.getInputStream(), 64 * 1024)
            cmdOutput = cmdSocket!!.getOutputStream()
            cmdOutput!!.write(makeStaInitReq(identity))
            cmdOutput!!.flush()

            val commandAck = cmdReader.readPacket(cmdInput!!)
            staDiagnosticLines += "InitCommandAck=type${commandAck.type}"
            if (commandAck.type != PtpConstants.INIT_CMD_ACK) {
                return@withContext Result.failure(
                    if (commandAck.type == PtpConstants.INIT_FAIL) CameraRefusedException(
                        context.getString(R.string.error_camera_refused)
                    ) else Exception(context.getString(R.string.error_handshake_bad_ack))
                )
            }
            val initAck = PtpIpProtocolCodec.decodeInitCommandAck(commandAck.payload) ?: return@withContext Result.failure(
                Exception(context.getString(R.string.error_handshake_empty))
            )
            val connectionNumber = initAck.connectionNumber
            initAck.responderGuidHex?.let { responderGuid = it }
            if (!isExpectedStaResponder(expectedResponderGuid, responderGuid)) {
                staDiagnosticLines +=
                    "responder=UNEXPECTED expected=$expectedResponderGuid actual=$responderGuid"
                throw UnexpectedStaResponderException(responderGuid)
            }
            evtSocket = newSocket().apply {
                soTimeout = STA_HANDSHAKE_TIMEOUT_MS
                connect(InetSocketAddress(ip, PtpConstants.PTP_PORT), CONNECT_TIMEOUT_MS)
            }
            evtInput = evtSocket!!.getInputStream()
            val eventInit = PtpIpProtocolCodec.encodeInitEventRequest(connectionNumber)
            evtSocket!!.getOutputStream().write(eventInit)
            evtSocket!!.getOutputStream().flush()
            val eventAck = evtReader.readPacket(evtInput!!)
            staDiagnosticLines += "InitEventAck=type${eventAck.type}"
            if (eventAck.type != PtpConstants.INIT_EVT_ACK) {
                return@withContext Result.failure(
                    Exception(context.getString(R.string.error_event_handshake))
                )
            }

            // Nikon PC/STA traces always open PTP session 1 from transaction 0; the Init ACK value
            // above is only the Event socket's connection number.
            tid = -1
            sendCmd(PtpConstants.OPEN_SESSION, 1)
            val openResponse = recvResp()
            staDiagnosticLines += "OpenSession=${hexResponse(openResponse)}"
            if (openResponse != PtpConstants.RESPONSE_OK &&
                openResponse != PtpConstants.SESSION_ALREADY_OPEN
            ) {
                return@withContext Result.failure(
                    Exception(
                        context.getString(
                            R.string.error_open_session,
                            PtpConstants.translateResponse(context, openResponse),
                        )
                    )
                )
            }
            sessionOpen = true
            initializeStaBrowsingSession(
                allowPairing = allowPairing,
                exploreAlbumAccess = exploreAlbumAccess,
                forceProfilePairing = forceProfilePairing,
                onConnectingStarted = onConnectingStarted,
                onPairingStarted = onPairingStarted,
            )
            cmdSocket?.soTimeout = SO_TIMEOUT_MS
            evtSocket?.soTimeout = SO_TIMEOUT_MS
            startEvtThread()
            Result.success(Unit)
        } catch (error: Exception) {
            staDiagnosticLines +=
                "error=${error.javaClass.simpleName}:${error.message.orEmpty()}"
            close()
            Result.failure(error)
        }
    }

    /** Opens a raw PTP session over an Android USB Host connection. */
    suspend fun connectUsb(
        manager: UsbManager,
        device: UsbDevice
    ): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            usbDeviceSerial = runCatching { device.serialNumber }
                .getOrNull()
                ?.trim()
                ?.takeIf(String::isNotEmpty)
            if (FileOrderProbe.enabled) FileOrderProbe.beginConnection("USB")
            log { "USB_CONNECT open device=${device.deviceName}" }
            tid = -1
            val transport = UsbPtpConnection.open(manager, device).getOrThrow()
            usbPtp = transport
            transport.readTimeoutMs = USB_CONNECT_TIMEOUT_MS

            // Android 原生 MTP host 会先以 transaction 0 打开会话，
            // 再从 transaction 1 开始读取 DeviceInfo 并执行后续操作。
            log { "USB_CONNECT open-session" }
            sendCmd(PtpConstants.OPEN_SESSION, 1)
            val resp = recvResp()
            log { "USB_CONNECT open-session response=0x${resp.toString(16)}" }
            if (resp != PtpConstants.RESPONSE_OK && resp != PtpConstants.SESSION_ALREADY_OPEN) {
                throw Exception(
                    context.getString(
                        R.string.error_open_session,
                        PtpConstants.translateResponse(context, resp)
                    )
                )
            }
            sessionOpen = true

            log { "USB_CONNECT device-info" }
            sendCmd(PtpConstants.GET_DEVICE_INFO)
            val (deviceInfoResp, deviceInfoData) = recvRespWithPayload()
            log { "USB_CONNECT device-info response=0x${deviceInfoResp.toString(16)}" }
            if (deviceInfoResp != PtpConstants.RESPONSE_OK) {
                throw Exception(
                    context.getString(
                        R.string.error_read_device_info,
                        PtpConstants.translateResponse(context, deviceInfoResp)
                    )
                )
            }
            if (deviceInfoData != null) {
                runCatching { cacheDeviceInfo(deviceInfoData) }
                    .onSuccess { info ->
                        if (FileOrderProbe.enabled) {
                            FileOrderProbe.recordCapabilities(
                                manufacturer = info.manufacturer,
                                model = info.model,
                                deviceVersion = info.deviceVersion,
                                operations = info.operations,
                            )
                        }
                    }
                    .onFailure { error ->
                        if (FileOrderProbe.enabled) {
                            FileOrderProbe.recordCapabilityFailure(
                                "${error.javaClass.simpleName}: ${error.message.orEmpty()}"
                            )
                        }
                    }
            } else if (FileOrderProbe.enabled) {
                FileOrderProbe.recordCapabilityFailure("response OK but payload is empty")
            }

            transport.readTimeoutMs = SO_TIMEOUT_MS
            connectedUsbManager = manager
            connectedUsbDevice = device
            log { "USB_CONNECT ready" }
            Result.success(Unit)
        } catch (e: Exception) {
            log { "USB_CONNECT failed: ${e.javaClass.simpleName}: ${e.message}" }
            close()
            Result.failure(e)
        }
    }

    /**
     * Replaces the media-browsing PTP session with a fresh USB remote-control session.
     *
     * Nikon's USB tethering path requires a newly opened session and drains GetEventEx once
     * before entering control mode. DeviceInfo remains cached from the physical connection so
     * switching from browsing to remote control does not query it a second time.
     */
    internal suspend fun refreshUsbRemoteSession(): String =
        ioMutex.withLock {
            withContext(Dispatchers.IO) {
                val manager = connectedUsbManager
                    ?: throw IllegalStateException("USB manager unavailable")
                val device = connectedUsbDevice
                    ?: throw IllegalStateException("USB device unavailable")

                if (sessionOpen) {
                    runCatching {
                        sendCmd(PtpConstants.CLOSE_SESSION)
                        recvResp()
                    }
                    sessionOpen = false
                }
                runCatching { usbPtp?.close() }
                usbPtp = null
                val settleStartedAt = SystemClock.elapsedRealtime()
                val reopenSettleMs = USB_REMOTE_REOPEN_SETTLE_MS
                log { "USB_REMOTE settling before fresh session ${reopenSettleMs}ms" }
                kotlinx.coroutines.delay(reopenSettleMs)

                var openResponse = -1
                repeat(2) { attempt ->
                    val transport = UsbPtpConnection.open(manager, device).getOrThrow()
                    usbPtp = transport
                    transport.readTimeoutMs = USB_CONNECT_TIMEOUT_MS
                    // The verified Nikon remote trace starts its fresh session at transaction 1.
                    tid = 0

                    sendCmd(PtpConstants.OPEN_SESSION, 1)
                    openResponse = recvResp()
                    if (openResponse == PtpConstants.SESSION_ALREADY_OPEN) {
                        runCatching {
                            sendCmd(PtpConstants.CLOSE_SESSION)
                            recvResp()
                        }
                        runCatching { transport.close() }
                        usbPtp = null
                        if (attempt == 0) {
                            kotlinx.coroutines.delay(USB_REMOTE_REOPEN_SETTLE_MS)
                        }
                    } else {
                        if (openResponse != PtpConstants.RESPONSE_OK) {
                            throw IllegalStateException(
                                "OpenSession response=0x%04X".format(openResponse)
                            )
                        }
                        sessionOpen = true

                        sendCmd(0x941C) // Nikon GetEventEx: drain stale events after OpenSession.
                        val drainResponse = recvRespWithPayload().first

                        liveViewImageOperation =
                            preferredLiveViewImageOperation(cachedDeviceInfo?.operations)
                        val eventReaderStarted = transport.startEventReader()

                        transport.readTimeoutMs = SO_TIMEOUT_MS
                        remoteControlModeSet = false
                        remoteMovieApplicationPropSet = false
                        remoteMovieApplicationOpSet = false
                        return@withContext buildString {
                            append("session=0x%04X".format(openResponse))
                            append(" drain=0x%04X".format(drainResponse))
                            append(" info=cached")
                            append(" irq=").append(if (eventReaderStarted) "Y" else "N")
                            append(" settle=").append(reopenSettleMs).append("/")
                                .append(SystemClock.elapsedRealtime() - settleStartedAt)
                                .append("ms")
                        }
                    }
                }

                throw IllegalStateException(
                    "Fresh OpenSession response=0x%04X".format(openResponse)
                )
            }
        }

    private fun startEvtThread() {
        val socket = evtSocket ?: return
        val input = evtInput ?: return
        evtThread = Thread {
            try {
                // 事件通道长时间无事件是常态：握手后取消读超时，阻塞等待即可。
                //（之前沿用 60s 超时会让本线程在空闲后静默退出，之后事件通道无人读、
                // PING 无人应答，长时间挂机可能被相机判定失联。）
                socket.soTimeout = 0
                val output = socket.getOutputStream()
                while (true) {
                    val packet = evtReader.readPacket(input)
                    when (packet.type) {
                        // 部分机型在事件通道发 PING 保活，必须在本通道应答。
                        PtpConstants.PING -> sendPong(output)
                        // 不在事件线程执行任何相机命令；只投递轻量事件，命令通道仍由
                        // CameraViewModel 按前台优先级统一调度。缓冲满时命令轮询仍会兜底。
                        PtpConstants.EVENT -> if (staAlbumAccessValidated) {
                            parsePtpIpEvent(packet.payload)?.let(ptpIpEventChannel::trySend)
                        }
                    }
                }
            } catch (_: Exception) {
                // socket 关闭/连接断开：线程自然结束。掉线由命令通道的心跳发现并触发重连。
            }
        }.apply {
            isDaemon = true
            name = "PTP-EvtThread"
            start()
        }
    }

    suspend fun getStorageIds(): List<Int> = ioMutex.withLock {
        withContext(Dispatchers.IO) {
            try {
                prefetchedStorageIds?.let { storageIds ->
                    prefetchedStorageIds = null
                    return@withContext storageIds
                }
                sendCmd(PtpConstants.GET_STORAGE_IDS)
                val (respCode, data) = recvRespWithPayload()
                if (respCode != PtpConstants.RESPONSE_OK || data == null || data.size < 4) {
                    return@withContext emptyList()
                }
                parsePtpUInt32Array(data) ?: emptyList()
            } catch (_: Exception) {
                emptyList()
            }
        }
    }

    internal data class StorageIdsResult(
        val storageIds: List<Int>,
        val successful: Boolean,
        val responseCode: Int?,
        val payloadBytes: Int,
        val error: String? = null,
    )

    /** STA-only status-preserving variant; an IO/response failure must not become an empty card. */
    internal suspend fun getStaStorageIdsWithStatus(): StorageIdsResult = ioMutex.withLock {
        withContext(Dispatchers.IO) {
            prefetchedStorageIds?.let { storageIds ->
                prefetchedStorageIds = null
                return@withContext StorageIdsResult(
                    storageIds = storageIds,
                    successful = true,
                    responseCode = PtpConstants.RESPONSE_OK,
                    payloadBytes = 4 + storageIds.size * 4,
                )
            }
            try {
                sendCmd(PtpConstants.GET_STORAGE_IDS)
                val (response, data) = recvRespWithPayload()
                if (response != PtpConstants.RESPONSE_OK || data == null || data.size < 4) {
                    return@withContext StorageIdsResult(
                        storageIds = emptyList(),
                        successful = false,
                        responseCode = response,
                        payloadBytes = data?.size ?: 0,
                    )
                }
                val storageIds = parsePtpUInt32Array(data)
                if (storageIds == null) {
                    val count = data.getIntLE(0)
                    return@withContext StorageIdsResult(
                        storageIds = emptyList(),
                        successful = false,
                        responseCode = response,
                        payloadBytes = data.size,
                        error = "malformed-count=$count",
                    )
                }
                StorageIdsResult(
                    storageIds = storageIds,
                    successful = true,
                    responseCode = response,
                    payloadBytes = data.size,
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                StorageIdsResult(
                    storageIds = emptyList(),
                    successful = false,
                    responseCode = null,
                    payloadBytes = 0,
                    error = "${error.javaClass.simpleName}:${error.message.orEmpty()}",
                )
            }
        }
    }

    suspend fun keepalive(): Boolean = ioGate.withIdleCommand(skippedValue = true) {
        withContext(Dispatchers.IO) {
            try {
                sendCmd(PtpConstants.GET_STORAGE_IDS)
                // 能收到【任何】响应就证明链路活着；非 OK（如相机忙碌时的 DeviceBusy）
                // 不代表断线——按响应码判死会把健康连接误杀掉重连，相机侧反而可能
                // 因此挂会话/关热点。只有 IO 异常（socket 死）才算失联。
                recvResp()
                true
            } catch (_: Exception) {
                false
            }
        }
    }

    internal data class ObjectHandlesResult(
        val handles: List<Int>,
        val successful: Boolean,
        val responseCode: Int?,
        val payloadBytes: Int,
        val error: String? = null,
        val fromPrefetch: Boolean = false,
    )

    internal suspend fun getObjectHandlesWithStatus(
        storageId: Int = -1,
    ): ObjectHandlesResult = ioMutex.withLock {
        withContext(Dispatchers.IO) {
            prefetchedStaObjectHandles?.takeIf { it.queryStorageId == storageId }?.let { cached ->
                prefetchedStaObjectHandles = null
                return@withContext ObjectHandlesResult(
                    handles = cached.handles,
                    successful = true,
                    responseCode = PtpConstants.RESPONSE_OK,
                    payloadBytes = 4 + cached.handles.size * 4,
                    fromPrefetch = true,
                )
            }
            try {
                sendCmd(PtpConstants.GET_OBJECT_HANDLES, storageId, -1, 0)
                val (respCode, data) = recvRespWithPayload()
                if (respCode != PtpConstants.RESPONSE_OK || data == null || data.size < 4) {
                    return@withContext ObjectHandlesResult(
                        handles = emptyList(),
                        successful = false,
                        responseCode = respCode,
                        payloadBytes = data?.size ?: 0,
                    )
                }
                val handles = parsePtpUInt32Array(data)
                if (handles == null) {
                    val count = data.getIntLE(0)
                    return@withContext ObjectHandlesResult(
                        handles = emptyList(),
                        successful = false,
                        responseCode = respCode,
                        payloadBytes = data.size,
                        error = "malformed-count=$count",
                    )
                }
                ObjectHandlesResult(
                    handles = handles,
                    successful = true,
                    responseCode = respCode,
                    payloadBytes = data.size,
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                ObjectHandlesResult(
                    handles = emptyList(),
                    successful = false,
                    responseCode = null,
                    payloadBytes = 0,
                    error = "${error.javaClass.simpleName}:${error.message.orEmpty()}",
                )
            }
        }
    }

    /**
     * 通过 PTP GetThumb 获取缩略图 JPEG 字节。相机【确认】无缩略图（No_Thumbnail_Present /
     * Invalid_Object_Handle）返回 null——调用方可安全负缓存、不再重试；
     * 其它非 OK 响应（如设备忙）与 IO 失败一律抛出——那是瞬时状态，负缓存会把
     * 恰好赶上相机忙碌时段的整批缩略图永久打成"无图"。与其它命令共用 ioMutex。
     */
    suspend fun getThumbnail(handle: Int): ByteArray? = ioMutex.withLock {
        withContext(Dispatchers.IO) {
            if (staDirectObjectReadValidated) {
                staDirectThumbnails[handle]?.let { return@withContext it }
                if (handle in staDirectNoThumbnail) return@withContext null
                val file = staDirectFiles[handle]
                val thumbnail = when (file?.extension) {
                    ".nef" -> readStaDirectRawThumbnailInternal(file)
                    ".mov", ".mp4" -> {
                        // Z30 通常把视频封面放在最前 128 KiB。先走与旧目录扫描相同的
                        // 小探针，只有确实没有封面时才扩大到有界 8 MiB 视频解析。
                        val headerResult = readStaDirectObjectHeaderInternal(handle)
                        cacheStaDirectObjectHeader(handle, headerResult)
                        headerResult.thumbnail ?: readStaDirectVideoThumbnailInternal(file)
                    }
                    else -> readStaDirectObjectHeaderInternal(handle).let { result ->
                        cacheStaDirectObjectHeader(handle, result)
                        result.thumbnail
                    }
                }
                thumbnail?.let { bytes ->
                    rememberStaDirectThumbnail(handle, bytes)
                    return@withContext bytes
                }
                // RAW/video parsers negative-cache only a completed deterministic miss. Do not
                // blanket-cache null here: short reads and rejected commands must remain retryable.
                if (file == null || file.extension == ".jpg") {
                    staDirectNoThumbnail += handle
                }
                return@withContext null
            }
            sendCmd(PtpConstants.GET_THUMB, handle)
            val (respCode, data) = recvRespWithPayload()
            when (respCode) {
                PtpConstants.RESPONSE_OK -> data
                PtpConstants.NO_THUMBNAIL_PRESENT,
                PtpConstants.INVALID_OBJECT_HANDLE -> null
                else -> throw Exception("GetThumb: ${PtpConstants.translateResponse(context, respCode)}")
            }
        }
    }

    /**
     * 获取 FHD (1920×1080) 预览图 JPEG 字节。与 [getThumbnail] 共用 [ioMutex] 串行化。
     * 仅相机明确返回“不支持”时才记住该会话无 FHD 能力；忙、对象异常和空数据都按临时失败处理。
     * 临时失败返回 null，调用方静默回退到缩略图，不影响后续照片再次尝试。
     */
    suspend fun getFhdPicture(
        handle: Int,
        retryDeviceBusy: Boolean = true,
    ): ByteArray? = ioGate.withInteractive {
        withContext(Dispatchers.IO) {
            val startedAt = android.os.SystemClock.elapsedRealtime()
            // 已判定不支持：直接返回，免去每页一次注定失败的往返（预览秒回退缩略图）。
            if (fhdSupported == false) return@withContext null
            try {
                var busyRetriesRemaining = if (retryDeviceBusy) FHD_DEVICE_BUSY_RETRIES else 0
                var result: ByteArray? = null
                requestLoop@ while (true) {
                    sendCmd(PtpConstants.NK_GET_FHD_PICTURE, handle)
                    val (respCode, data) = recvRespWithPayload()
                    val disposition = classifyFhdResponse(respCode, data?.isNotEmpty() == true)
                    fhdSupported = updateFhdSupport(fhdSupported, disposition)
                    when (disposition) {
                        FhdResponseDisposition.SUCCESS -> {
                            val payload = checkNotNull(data)
                            log {
                                "GetFhdPicture handle=$handle bytes=${payload.size} " +
                                    "network=${android.os.SystemClock.elapsedRealtime() - startedAt}ms"
                            }
                            result = payload
                            break@requestLoop
                        }
                        FhdResponseDisposition.UNSUPPORTED -> {
                            // 已经成功过的会话不因单个对象的异常响应推翻能力；未知状态下收到
                            // 标准不支持才熔断。
                            log {
                                "GetFhdPicture unsupported (resp=0x${respCode.toString(16)}), " +
                                    "latched=${fhdSupported == false}"
                            }
                            break@requestLoop
                        }
                        FhdResponseDisposition.TRANSIENT_FAILURE -> {
                            if (respCode == PtpConstants.DEVICE_BUSY && busyRetriesRemaining > 0) {
                                busyRetriesRemaining--
                                log {
                                    "GetFhdPicture busy handle=$handle, retrying " +
                                        "remaining=$busyRetriesRemaining"
                                }
                                delay(FHD_DEVICE_BUSY_RETRY_DELAY_MS)
                                continue
                            }
                            log {
                                "GetFhdPicture transient handle=$handle " +
                                    "resp=0x${respCode.toString(16)} bytes=${data?.size ?: 0}"
                            }
                            break@requestLoop
                        }
                    }
                }
                result
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // 未完整收完响应的连接不可再复用，否则下一条命令可能读到本事务残包。
                log { "GetFhdPicture transport failed: ${e.javaClass.simpleName}: ${e.message}" }
                closeQuietly()
                null
            }
        }
    }

    /**
     * Paired-STA preview. Prefer the camera-generated FHD/LargeThumb operation when the current
     * profile permits it; paired-computer profiles that deny those operations fall back to the
     * exact independent JPEG range described by the object's MPF index. No path reads the original
     * primary JPEG stream.
     */
    suspend fun getStaFhdPicture(
        handle: Int,
        retryDeviceBusy: Boolean = true,
    ): ByteArray? = ioGate.withInteractive {
        withContext(Dispatchers.IO) {
            if (!staDirectObjectReadValidated) return@withContext null
            val advertisedOperations = cachedDeviceInfo?.operations.orEmpty()
            val candidates = listOf(
                PtpConstants.NK_GET_FHD_PICTURE to "GetFhdPicture",
                PtpConstants.NK_GET_LARGE_THUMB to "GetLargeThumb",
            )
            try {
                suspend fun requestCameraPreview(): ByteArray? {
                    for ((operation, operationName) in candidates) {
                        val advertised = operation in advertisedOperations
                        val knownSupport = when (operation) {
                            PtpConstants.NK_GET_FHD_PICTURE -> staFhdPictureSupported
                            else -> staLargeThumbSupported
                        }
                        // GetLargeThumb is a fallback only when the current camera declares it. The
                        // historical 0x920F path is still probed once because Nikon bodies do not
                        // consistently include every private operation in DeviceInfo.
                        if (knownSupport == false ||
                            (operation == PtpConstants.NK_GET_LARGE_THUMB && !advertised)
                        ) {
                            continue
                        }

                        var busyRetriesRemaining = if (retryDeviceBusy) FHD_DEVICE_BUSY_RETRIES else 0
                        while (true) {
                            val startedAt = SystemClock.elapsedRealtime()
                            sendCmd(operation, handle)
                            val (response, data) = recvRespWithPayload()
                            val payload = data?.takeIf {
                                response == PtpConstants.RESPONSE_OK && it.isNotEmpty()
                            }
                            val bounds = payload?.let { bytes ->
                                BitmapFactory.Options().also { options ->
                                    options.inJustDecodeBounds = true
                                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
                                }
                            }
                            val isJpeg = payload?.let {
                                it.size >= 2 && it[0] == 0xFF.toByte() && it[1] == 0xD8.toByte()
                            } ?: false
                            val validPreview = payload?.takeIf {
                                isJpeg && (bounds?.outWidth ?: 0) > 0 &&
                                    (bounds?.outHeight ?: 0) > 0
                            }
                            if (PhotoGenerationProbe.enabled) {
                                PhotoGenerationProbe.note(
                                    "STA-PREVIEW",
                                    ("camera:%s handle=0x%08X opcode=0x%04X advertised=%s " +
                                        "response=0x%04X bytes=%d jpeg=%s dimensions=%dx%d " +
                                        "networkMs=%d").format(
                                        operationName,
                                        handle,
                                        operation,
                                        advertised,
                                        response,
                                        data?.size ?: 0,
                                        isJpeg,
                                        bounds?.outWidth ?: 0,
                                        bounds?.outHeight ?: 0,
                                        SystemClock.elapsedRealtime() - startedAt,
                                    ),
                                )
                            }
                            if (validPreview != null) {
                                if (operation == PtpConstants.NK_GET_FHD_PICTURE) {
                                    staFhdPictureSupported = true
                                } else {
                                    staLargeThumbSupported = true
                                }
                                return validPreview
                            }
                            if (response == PtpConstants.DEVICE_BUSY && busyRetriesRemaining > 0) {
                                busyRetriesRemaining--
                                delay(FHD_DEVICE_BUSY_RETRY_DELAY_MS)
                                continue
                            }
                            if (response == PtpConstants.OPERATION_NOT_SUPPORTED || response == 0x200F) {
                                if (operation == PtpConstants.NK_GET_FHD_PICTURE) {
                                    staFhdPictureSupported = false
                                } else {
                                    staLargeThumbSupported = false
                                }
                            }
                            break
                        }
                    }
                    return null
                }

                requestCameraPreview() ?: when (val file = staDirectFiles[handle]) {
                    null -> null
                    else -> when (file.extension) {
                        ".jpg" -> readStaDirectJpegMpfPreviewInternal(handle)
                        ".nef" -> readStaDirectRawPreviewInternal(file)
                        else -> null
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (PhotoGenerationProbe.enabled) {
                    PhotoGenerationProbe.note(
                        "STA-PREVIEW",
                        "preview handle=0x%08X error=%s:%s".format(
                            handle,
                            e.javaClass.simpleName,
                            e.message.orEmpty(),
                        ),
                    )
                }
                // A transport failure can leave a partial PTP/IP data phase behind.
                closeQuietly()
                null
            }
        }
    }

    /**
     * 下载文件头若干字节用于 EXIF 解析。通过 [NK_GET_PARTIAL_OBJECT_EX] 从偏移 0 读取
     * [maxSize] 字节（默认 128KB，足以覆盖绝大多数 JPEG 的 EXIF 段）；与 [ioMutex]
     * 串行化。任何失败返回 null——EXIF 是纯体验增强，不应为失败产生视觉噪音。
     */
    suspend fun readExifHeader(handle: Int, maxSize: Int = 128 * 1024): ByteArray? =
        ioGate.withInteractive {
            withContext(Dispatchers.IO) {
                try {
                    if (staDirectObjectReadValidated) {
                        staDirectRecentHeaders[handle]?.let { cached ->
                            return@withContext if (cached.size <= maxSize) {
                                cached
                            } else {
                                cached.copyOf(maxSize)
                            }
                        }
                    }
                    sendCmd(PtpConstants.NK_GET_PARTIAL_OBJECT_EX, handle, 0, 0, maxSize, 0)
                    val (respCode, data) = recvRespWithPayload()
                    if (respCode == PtpConstants.RESPONSE_OK && data != null && data.isNotEmpty()) data
                    else {
                        log { "ReadExifHeader handle=$handle resp=0x${respCode.toString(16)} len=${data?.size ?: 0}" }
                        null
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    log { "ReadExifHeader transport failed: ${e.javaClass.simpleName}: ${e.message}" }
                    closeQuietly()
                    null
                }
            }
        }

    /**
     * 为当前大图的 FHD + EXIF 组合保留交互优先级，但不持续占用 [ioMutex]：两项之间的
     * 手机解码仍可并行进行，只是不允许原片传输抢先开始下一块。
     */
    internal suspend fun <T> withInteractivePreviewPriority(block: suspend () -> T): T =
        ioGate.withInteractivePriority(block)

    suspend fun streamFileInfo(
        handles: List<Int>,
        batchSize: Int = 20,
        onBatch: suspend (List<CameraFileInfo>, Int, Int) -> Unit
    ): Boolean = withContext(Dispatchers.IO) {
        val loadContext = coroutineContext
        val total = handles.size
        var loaded = 0
        var allObjectInfoSucceeded = true
        handles.chunked(batchSize).forEach { batch ->
            val probeStartedAtMs = if (FileOrderProbe.enabled) SystemClock.elapsedRealtime() else 0L
            // 每批单独持锁，批间释放 ioMutex：缩略图模式下缩略图请求可在批间插入，
            // 从而随列表一起渐进出图，而不是等整份列表加载完才开始。
            // 批内每个 ObjectInfo 之间也检查取消：进入监看时最多等当前一条事务收尾，
            // 不会被余下 19 条已经开始的整批扫描挡住。
            // IO 异常（掉线/读超时）直接向上抛给调用方终止扫描：逐个 handle 硬试会让
            // 每个都等满 60s 读超时、扫描假死数十分钟；单文件 PTP 级失败在
            // getObjectInfoInternal 内已按 null 跳过，不会走到这里。
            val files = ioMutex.withLock {
                batch.mapNotNull { handle ->
                    loadContext.ensureActive()
                    val result = getObjectInfoInternal(handle)
                    if (!result.successful) allObjectInfoSucceeded = false
                    result.file
                }
            }
            if (FileOrderProbe.enabled) {
                FileOrderProbe.recordObjectInfoBatch(
                    requestedHandles = batch,
                    files = files,
                    elapsedMs = SystemClock.elapsedRealtime() - probeStartedAtMs,
                )
            }
            loaded += files.size
            if (files.isNotEmpty()) {
                onBatch(files, loaded, total)
            }
        }
        allObjectInfoSucceeded
    }

    /**
     * Paired Z30 fallback: ObjectInfo is AccessDenied, while GetObjectSize and
     * GetPartialObjectEx remain available. Build a progressive catalog from those two operations.
     * This method is never selected unless the STA handshake verified that exact capability pair.
     */
    suspend fun streamStaDirectFileInfo(
        handles: List<Int>,
        storageIds: List<Int> = emptyList(),
        batchSize: Int = 12,
        onBatch: suspend (List<CameraFileInfo>, Int, Int) -> Unit,
    ): Boolean = withContext(Dispatchers.IO) {
        check(staDirectObjectReadValidated) { "STA direct object reads were not validated" }
        require(batchSize > 0) { "batchSize must be positive" }
        val loadContext = coroutineContext
        val total = handles.size
        var processed = 0
        var allSucceeded = true
        ioMutex.withLock {
            loadStaDirectOriginalFileNamesInternal()
            loadStaDirectObjectsMetadataInternal(storageIds)
            ensureStaDirectFileNumberAnchorsInternal(
                listOf((storageIds.singleOrNull() ?: -1) to handles),
            )
        }
        var nextHandleIndex = 0
        while (nextHandleIndex < total) {
            // Direct STA needs a 128 KiB header read per object. Publishing the first item
            // immediately avoids holding an empty screen until a full 12-object batch completes;
            // after the first four items we return to the normal batch size to limit UI churn.
            val currentBatchSize = when {
                nextHandleIndex == 0 -> 1
                nextHandleIndex < 4 -> minOf(3, batchSize)
                else -> batchSize
            }
            val batchEnd = minOf(nextHandleIndex + currentBatchSize, total)
            val batch = handles.subList(nextHandleIndex, batchEnd)
            val files = ioMutex.withLock {
                batch.mapNotNull { handle ->
                    loadContext.ensureActive()
                    val result = readStaDirectIndexedObjectInternal(
                        handle = handle,
                        storageId = storageIds.singleOrNull(),
                    )
                    if (!result.successful) allSucceeded = false
                    cacheStaDirectObjectHeader(handle, result)
                    result.file
                }
            }
            processed += batch.size
            if (files.isNotEmpty()) onBatch(files, processed, total)
            nextHandleIndex = batchEnd
        }
        allSucceeded
    }

    /**
     * STA-direct counterpart of [streamMergedFileInfo]. ObjectInfo is unavailable in this mode, so
     * each card keeps its own filename anchor and the already indexed capture date decides which
     * head is published next. The first publication still uses the small 1 -> 3 -> batch ramp to
     * preserve the proven STA first-screen behaviour.
     */
    suspend fun streamStaDirectMergedFileInfo(
        newestFirstHandlesByStorage: List<Pair<Int, List<Int>>>,
        storageIds: List<Int> = newestFirstHandlesByStorage.map { it.first },
        batchSize: Int = 12,
        onBatch: suspend (List<CameraFileInfo>, Int, Int) -> Unit,
    ): Boolean = withContext(Dispatchers.IO) {
        check(staDirectObjectReadValidated) { "STA direct object reads were not validated" }
        require(batchSize > 0) { "batchSize must be positive" }
        val groups = newestFirstHandlesByStorage.filter { it.second.isNotEmpty() }
        if (groups.isEmpty()) return@withContext true

        val loadContext = coroutineContext
        ioMutex.withLock {
            loadStaDirectOriginalFileNamesInternal()
            loadStaDirectObjectsMetadataInternal(storageIds)
            ensureStaDirectFileNumberAnchorsInternal(groups)
        }

        val total = groups.sumOf { it.second.size }
        val cursors = IntArray(groups.size)
        val heads = MutableList<CameraFileInfo?>(groups.size) { null }
        var completed = 0
        var allSucceeded = true

        while (completed < total) {
            val currentBatchSize = when {
                completed == 0 -> 1
                completed < 4 -> minOf(3, batchSize)
                else -> batchSize
            }
            var requestedHandles = 0
            val completedBeforeBatch = completed
            val requestBudget = maxOf(groups.size, currentBatchSize + groups.size - 1)
            val output = ioMutex.withLock {
                buildList {
                    while (size < currentBatchSize && completed < total) {
                        groups.indices.forEach { groupIndex ->
                            if (heads[groupIndex] != null) return@forEach
                            val (storageId, handles) = groups[groupIndex]
                            while (cursors[groupIndex] < handles.size) {
                                if (requestedHandles >= requestBudget) return@forEach
                                loadContext.ensureActive()
                                val handle = handles[cursors[groupIndex]++]
                                requestedHandles++
                                val result = readStaDirectIndexedObjectInternal(handle, storageId)
                                cacheStaDirectObjectHeader(handle, result)
                                if (!result.successful) allSucceeded = false
                                val file = result.file
                                if (file == null) {
                                    completed++
                                } else {
                                    heads[groupIndex] = file
                                    break
                                }
                            }
                        }

                        val hasUnresolvedGroup = groups.indices.any { groupIndex ->
                            heads[groupIndex] == null &&
                                cursors[groupIndex] < groups[groupIndex].second.size
                        }
                        if (hasUnresolvedGroup) break

                        val selected = selectNewestFileHeadIndex(heads) ?: break
                        add(checkNotNull(heads[selected]))
                        heads[selected] = null
                        completed++
                    }
                }
            }
            if (output.isNotEmpty()) {
                onBatch(output, completed, total)
            } else if (completed == completedBeforeBatch && requestedHandles == 0) {
                error("Merged STA direct scan made no progress")
            }
        }
        allSucceeded
    }

    /** Must be called while [ioMutex] is held. One tiny index replaces one 128 KiB date probe/item. */
    private fun loadStaDirectObjectsMetadataInternal(
        storageIds: List<Int>,
        forceRefresh: Boolean = false,
    ) {
        if (staDirectObjectsMetadataAttempted && !forceRefresh) return
        staDirectObjectsMetadataAttempted = true
        val advertised = cachedDeviceInfo?.operations
            ?.contains(PtpConstants.NK_GET_OBJECTS_METADATA) == true
        if (!advertised) {
            staDirectMetadataDiagnostics.putIfAbsent(
                "objects-metadata",
                "direct GetObjectsMetaData advertised=false response=<skipped> mapped=0",
            )
            return
        }

        val queries = storageIds.filter { it != 0 && it != -1 }.distinct().ifEmpty { listOf(-1) }
        val reports = ArrayList<String>(queries.size)
        queries.forEach { storageId ->
            sendCmd(PtpConstants.NK_GET_OBJECTS_METADATA, storageId, 0, 0)
            val (response, data) = recvRespWithPayload()
            val dates = if (response == PtpConstants.RESPONSE_OK) {
                parseNikonObjectsMetadataCaptureDates(data)
            } else emptyMap()
            staDirectCaptureDates.putAll(dates)
            reports += "0x%08X:%s/%dB/%d".format(
                storageId,
                hexResponse(response),
                data?.size ?: 0,
                dates.size,
            )
        }
        staDirectMetadataDiagnostics["objects-metadata"] =
            "direct GetObjectsMetaData advertised=true queries=[${reports.joinToString(",")}] " +
            "mapped=${staDirectCaptureDates.size}"
    }

    /** Refreshes only the compact STA catalog index; unsupported bodies keep the header fallback. */
    internal suspend fun refreshStaDirectObjectsMetadata(storageIds: List<Int>) =
        withContext(Dispatchers.IO) {
            if (!staDirectObjectReadValidated) return@withContext
            ioMutex.withLock {
                loadStaDirectObjectsMetadataInternal(storageIds, forceRefresh = true)
            }
        }

    /**
     * One real JPEG/NEF MakerNote anchors Nikon's monotonically increasing file number. This is the
     * only unconditional 128 KiB catalog read; all other headers become thumbnail/preview cache misses.
     */
    private fun ensureStaDirectFileNumberAnchorsInternal(
        newestFirstHandlesByStorage: List<Pair<Int, List<Int>>>,
    ) {
        newestFirstHandlesByStorage.forEach { (storageId, handles) ->
            if (storageId != -1 && storageId in staDirectFileNumberAnchorsByStorage) {
                return@forEach
            }
            val anchorHandle = handles.firstOrNull { handle ->
                staDirectExtensionFromHandle(handle) == ".jpg" ||
                    staDirectExtensionFromHandle(handle) == ".nef"
            } ?: return@forEach
            val result = readStaDirectObjectHeaderInternal(anchorHandle)
            cacheStaDirectObjectHeader(anchorHandle, result)
            val makerFileInfo = staDirectRecentHeaders[anchorHandle]?.let(::nikonMakerFileInfo)
                ?: return@forEach
            val anchor = NikonFileNumberAnchor(
                handleSequence = anchorHandle and 0x00FFFFFF,
                directoryNumber = makerFileInfo.directoryNumber,
                fileNumber = makerFileInfo.fileNumber,
            )
            staDirectFileNumberAnchor = anchor
            if (storageId != -1) staDirectFileNumberAnchorsByStorage[storageId] = anchor
        }
    }

    /** Fast warm-cache catalog path; any uncertain field falls back to the proven header parser. */
    private fun readStaDirectIndexedObjectInternal(
        handle: Int,
        storageId: Int? = null,
    ): StaDirectObjectHeader {
        staDirectFiles[handle]?.let { cached ->
            return StaDirectObjectHeader(
                file = cached,
                thumbnail = staDirectThumbnails[handle],
                successful = true,
                thumbnailChecked = handle in staDirectThumbnails || handle in staDirectNoThumbnail,
            )
        }
        val extension = staDirectExtensionFromHandle(handle)
            ?: return readStaDirectObjectHeaderInternal(handle)
        val captureDate = staDirectCaptureDates[handle]
            ?: return readStaDirectObjectHeaderInternal(handle)
        val size = getObjectSizeInternal(handle)
            ?: return StaDirectObjectHeader(null, null, false)
        val fileNumberAnchor = storageId?.let(staDirectFileNumberAnchorsByStorage::get)
            ?: staDirectFileNumberAnchor.takeIf { storageId == null }
        val fileName = staDirectOriginalFileNames[handle]
            ?: fileNumberAnchor
                ?.let { deriveNikonMakerFileInfo(it, handle) }
                ?.let { nikonDefaultCameraFileName(it, extension) }
            ?: return readStaDirectObjectHeaderInternal(
                handle = handle,
                preferredFileNumberAnchor = fileNumberAnchor,
                allowSessionFileNumberAnchor = storageId == null,
            )
        return StaDirectObjectHeader(
            file = CameraFileInfo(
                handle = handle,
                size = size,
                fileName = fileName,
                captureDate = captureDate,
            ),
            thumbnail = null,
            successful = true,
            thumbnailChecked = false,
        )
    }

    private fun cacheStaDirectObjectHeader(handle: Int, result: StaDirectObjectHeader) {
        result.file?.let { file ->
            staDirectFiles[handle] = file
            result.thumbnail?.let { bytes -> rememberStaDirectThumbnail(handle, bytes) }
            // RAW/video bounded probes are lazy and non-authoritative. JPEG's parsed EXIF envelope is
            // authoritative, so a missing thumbnail can retain the existing session negative cache.
            if (result.thumbnailChecked && result.thumbnail == null && file.extension == ".jpg") {
                staDirectNoThumbnail += handle
            }
        }
    }

    /** Keeps recent encoded thumbnails under a strict byte budget; STA PTP IO serializes access. */
    private fun rememberStaDirectThumbnail(handle: Int, bytes: ByteArray) {
        if (bytes.size > STA_DIRECT_THUMBNAIL_CACHE_BYTES) {
            staDirectThumbnails.remove(handle)?.let { previous ->
                staDirectThumbnailBytes -= previous.size
            }
            return
        }
        val previous = staDirectThumbnails.put(handle, bytes)
        staDirectThumbnailBytes += bytes.size - (previous?.size ?: 0)
        while (staDirectThumbnailBytes > STA_DIRECT_THUMBNAIL_CACHE_BYTES &&
            staDirectThumbnails.size > 1
        ) {
            val eldest = staDirectThumbnails.entries.iterator().next()
            staDirectThumbnailBytes -= eldest.value.size
            staDirectThumbnails.remove(eldest.key)
        }
    }

    /** Retains only the useful beginning of a recent STA object; larger prefixes never grow the cap. */
    private fun rememberStaDirectPrefix(handle: Int, bytes: ByteArray, validLength: Int = bytes.size) {
        val retainedLength = minOf(validLength, bytes.size, STA_DIRECT_RECENT_PREFIX_BYTES)
        if (retainedLength <= 0) return
        val existing = staDirectRecentHeaders[handle]
        if (existing != null && existing.size >= retainedLength) return
        staDirectRecentHeaders[handle] = if (retainedLength == bytes.size) {
            bytes
        } else {
            bytes.copyOf(retainedLength)
        }
        while (staDirectRecentHeaders.size > STA_DIRECT_RECENT_PREFIX_COUNT) {
            staDirectRecentHeaders.remove(staDirectRecentHeaders.keys.first())
        }
    }

    private data class StaDirectObjectHeader(
        val file: CameraFileInfo?,
        val thumbnail: ByteArray?,
        val successful: Boolean,
        val thumbnailChecked: Boolean = true,
    )

    /** Must be called while [ioMutex] is held. Prefer exact standard MTP names when advertised. */
    private fun loadStaDirectOriginalFileNamesInternal() {
        if (staDirectFileNameListAttempted) return
        staDirectFileNameListAttempted = true
        val operations = cachedDeviceInfo?.operations.orEmpty()
        val propertyListAdvertised = PtpConstants.GET_OBJECT_PROP_LIST in operations
        var propertyResponse: Int? = null
        var propertyData: ByteArray? = null
        var propertyNames: Map<Int, String> = emptyMap()
        if (propertyListAdvertised) {
            sendCmd(
                PtpConstants.GET_OBJECT_PROP_LIST,
                -1,
                0,
                PtpConstants.OBJECT_PROP_OBJECT_FILE_NAME,
                0,
                0,
            )
            val result = recvRespWithPayload()
            propertyResponse = result.first
            propertyData = result.second
            if (propertyResponse == PtpConstants.RESPONSE_OK && propertyData != null) {
                propertyNames = parseObjectFileNamePropertyList(propertyData)
                staDirectOriginalFileNames.putAll(propertyNames)
            }
        }
        staDirectMetadataDiagnostics.putIfAbsent(
            "filename-list",
            ("direct filename GetObjectPropList advertised=%s response=%s " +
                "payloadBytes=%d names=%d sample=%s").format(
                    propertyListAdvertised,
                    propertyResponse?.let(::hexResponse) ?: "<skipped>",
                    propertyData?.size ?: 0,
                    propertyNames.size,
                    propertyNames.entries.take(4).joinToString(",") {
                        "0x%08X:%s".format(it.key, it.value)
                    }.ifEmpty { "<none>" },
                ),
        )
    }

    /** Must be called while [ioMutex] is held. Used only when the one-shot list missed a handle. */
    private fun readStaDirectOriginalFileNameInternal(handle: Int): String? {
        staDirectOriginalFileNames[handle]?.let { return it }
        if (staDirectFileNameValueSupported == false) return null
        val advertised = cachedDeviceInfo?.operations
            ?.contains(PtpConstants.GET_OBJECT_PROP_VALUE) == true
        if (!advertised) {
            staDirectFileNameValueSupported = false
            staDirectMetadataDiagnostics.putIfAbsent(
                "filename-value",
                "direct filename GetObjectPropValue advertised=false response=<skipped> name=<none>",
            )
            return null
        }
        sendCmd(
            PtpConstants.GET_OBJECT_PROP_VALUE,
            handle,
            PtpConstants.OBJECT_PROP_OBJECT_FILE_NAME,
        )
        val (response, data) = recvRespWithPayload()
        val fileName = if (response == PtpConstants.RESPONSE_OK && data != null) {
            parsePtpObjectFileName(data)?.first
        } else {
            null
        }
        staDirectFileNameValueSupported = fileName != null
        fileName?.let { staDirectOriginalFileNames[handle] = it }
        staDirectMetadataDiagnostics.putIfAbsent(
            "filename-value",
            ("direct filename GetObjectPropValue advertised=%s handle=0x%08X " +
                "response=%s payloadBytes=%d name=%s").format(
                    advertised,
                    handle,
                    hexResponse(response),
                    data?.size ?: 0,
                    fileName ?: "<none>",
                ),
        )
        return fileName
    }

    /** Must be called while [ioMutex] is held. */
    private fun readStaDirectObjectHeaderInternal(
        handle: Int,
        preferredFileNumberAnchor: NikonFileNumberAnchor? = null,
        allowSessionFileNumberAnchor: Boolean = true,
        requireJpegPreviewIndex: Boolean = false,
    ): StaDirectObjectHeader {
        val protocolFileName = readStaDirectOriginalFileNameInternal(handle)
        val size = staDirectFiles[handle]?.size?.takeIf { it > 0L }
            ?: getObjectSizeInternal(handle)
            ?: return StaDirectObjectHeader(null, null, false)
        val maximumHeaderBytes = minOf(size, STA_DIRECT_CATALOG_HEADER_BYTES.toLong()).toInt()
        val useShortJpegPrefix = !requireJpegPreviewIndex &&
            staDirectExtensionFromHandle(handle) == ".jpg" &&
            maximumHeaderBytes > STA_DIRECT_JPEG_THUMBNAIL_PREFIX_BYTES
        val initialRequestBytes = if (useShortJpegPrefix) {
            STA_DIRECT_JPEG_THUMBNAIL_PREFIX_BYTES
        } else {
            maximumHeaderBytes
        }
        val initialHeader = readStaDirectPrefixInternal(handle, initialRequestBytes)
            ?: return StaDirectObjectHeader(null, null, false)
        rememberStaDirectPrefix(handle, initialHeader)
        val header = if (useShortJpegPrefix &&
            needsStaDirectJpegHeaderExpansion(initialHeader, maximumHeaderBytes)
        ) {
            readStaDirectPrefixInternal(handle, maximumHeaderBytes)
                ?: return StaDirectObjectHeader(null, null, false)
        } else {
            initialHeader
        }
        if (header.isEmpty()) {
            return StaDirectObjectHeader(null, null, false)
        }
        rememberStaDirectPrefix(handle, header)

        val detectedExtension = staDirectObjectExtension(header)
        val embeddedNames = if (
            protocolFileName == null && staDirectEmbeddedFileNameAvailable[detectedExtension] != false
        ) {
            findEmbeddedCameraFileNames(header, includePtpStrings = false)
        } else {
            emptyList()
        }
        val embeddedFileName = embeddedNames.firstOrNull { candidate ->
            candidate.value.substringAfterLast('.', missingDelimiterValue = "")
                .equals(detectedExtension.removePrefix("."), ignoreCase = true)
        }?.value
        if (protocolFileName == null && detectedExtension !in staDirectEmbeddedFileNameAvailable) {
            staDirectEmbeddedFileNameAvailable[detectedExtension] = embeddedFileName != null
        }
        val makerFileInfo = if (detectedExtension == ".jpg" || detectedExtension == ".nef") {
            nikonMakerFileInfo(header)
        } else {
            null
        }
        if (makerFileInfo != null) {
            staDirectFileNumberAnchor = NikonFileNumberAnchor(
                handleSequence = handle and 0x00FFFFFF,
                directoryNumber = makerFileInfo.directoryNumber,
                fileNumber = makerFileInfo.fileNumber,
            )
        }
        val derivedFileInfo = makerFileInfo ?: preferredFileNumberAnchor
            ?.let { anchor -> deriveNikonMakerFileInfo(anchor, handle) }
            ?: staDirectFileNumberAnchor.takeIf { allowSessionFileNumberAnchor }?.let { anchor ->
            deriveNikonMakerFileInfo(anchor, handle)
        }
        val derivedFileName = derivedFileInfo?.let { fileInfo ->
            nikonDefaultCameraFileName(fileInfo, detectedExtension)
        }
        val originalFileName = protocolFileName ?: embeddedFileName ?: derivedFileName
        originalFileName?.let { staDirectOriginalFileNames[handle] = it }
        if (protocolFileName == null) {
            staDirectMetadataDiagnostics.putIfAbsent(
                "filename-header-$detectedExtension",
                ("direct filename header type=%s handle=0x%08X candidates=%s selected=%s " +
                    "number=%s source=%s").format(
                    detectedExtension,
                    handle,
                    embeddedNames.take(6).joinToString(",") {
                        "${it.offset}:${it.value}/${it.encoding}"
                    }.ifEmpty { "<none>" },
                    originalFileName ?: "<none>",
                    derivedFileInfo?.let {
                        "%03d/%04d".format(it.directoryNumber, it.fileNumber)
                    } ?: "<none>",
                    when {
                        embeddedFileName != null -> "embedded"
                        makerFileInfo != null -> "maker-note"
                        derivedFileName != null -> "handle-sequence"
                        else -> "fallback"
                    },
                ),
            )
        }
        val originalExtension = originalFileName
            ?.substringAfterLast('.', missingDelimiterValue = "")
            ?.takeIf(String::isNotEmpty)
            ?.let { ".$it".lowercase() }
        val extension = if (detectedExtension == ".bin" && originalExtension != null) {
            originalExtension
        } else {
            detectedExtension
        }
        var captureDate: String? = staDirectCaptureDates[handle]
        var thumbnail: ByteArray? = null
        when (extension) {
            ".jpg" -> {
                val envelope = jpegExifEnvelope(header)
                val mpfPreviews = parseJpegMpfPreviews(header, size)
                if (mpfPreviews.isNotEmpty()) staDirectJpegMpfPreviews[handle] = mpfPreviews
                val exifResult = parseStaDirectExif(envelope ?: header, isRaw = false)
                captureDate = exifResult.captureDate ?: captureDate
                thumbnail = exifResult.thumbnail
                val diagnostic =
                    ("direct JPEG handle=0x%08X header=%dB envelope=%dB container=%s mpf=%s " +
                        "fileInfo=%s date=%s thumbnail=%dB error=%s").format(
                        handle,
                        header.size,
                        envelope?.size ?: 0,
                        jpegContainerDiagnostics(header),
                        mpfPreviews.joinToString(",") {
                            "type=0x%06X/range=%d+%d".format(
                                it.imageType,
                                it.offset,
                                it.length,
                            )
                        }.ifEmpty { "<none>" },
                        makerFileInfo?.let {
                            "%03d/%04d".format(it.directoryNumber, it.fileNumber)
                        } ?: "<none>",
                        captureDate ?: "<none>",
                        thumbnail?.size ?: 0,
                        exifResult.error ?: "<none>",
                    )
                if (requireJpegPreviewIndex) {
                    // Replace the earlier short-prefix report once preview opens and completes MPF.
                    staDirectMetadataDiagnostics["jpeg"] = diagnostic
                } else {
                    staDirectMetadataDiagnostics.putIfAbsent("jpeg", diagnostic)
                }
            }
            ".nef" -> {
                val rawMetadata = parseNefHeaderMetadata(header)
                staDirectRawPreviews[handle] = rawMetadata.previews
                if (rawMetadata.previews.isNotEmpty()) staDirectRawIndexedPreviews += handle
                val exifResult = parseStaDirectExif(header, isRaw = true)
                captureDate = rawMetadata.captureDate ?: exifResult.captureDate ?: captureDate
                thumbnail = rawMetadata.previews.firstOrNull { reference ->
                    reference.offset + reference.length <= header.size
                }?.let { reference ->
                    header.copyOfRange(
                        reference.offset.toInt(),
                        reference.offset.toInt() + reference.length,
                    )
                } ?: largestEmbeddedJpeg(header) ?: exifResult.thumbnail
                staDirectMetadataDiagnostics.putIfAbsent(
                    "raw",
                    ("direct RAW handle=0x%08X header=%dB refs=%s requiredPrefix=%s " +
                        "fileInfo=%s date=%s thumbnail=%dB error=%s").format(
                        handle,
                        header.size,
                        rawMetadata.previews.take(4).joinToString(",") {
                            "${it.offset}+${it.length}"
                        }.ifEmpty { "<none>" },
                        rawMetadata.previews.firstOrNull()?.let {
                            (it.offset + it.length).toString()
                        } ?: "<none>",
                        makerFileInfo?.let {
                            "%03d/%04d".format(it.directoryNumber, it.fileNumber)
                        } ?: "<none>",
                        captureDate ?: "<none>",
                        thumbnail?.size ?: 0,
                        exifResult.error ?: "<none>",
                    ),
                )
            }
            ".mov", ".mp4" -> {
                captureDate = staDirectVideoCaptureDate(header) ?: captureDate
                var tailBytes = 0
                if (captureDate == null && size > header.size) {
                    val requestSize = minOf(size, STA_DIRECT_VIDEO_TAIL_BYTES.toLong()).toInt()
                    val tail = readStaDirectPartialInternal(
                        handle = handle,
                        offset = (size - requestSize).coerceAtLeast(0L),
                        maxSize = requestSize,
                    )
                    tailBytes = tail?.size ?: 0
                    captureDate = tail?.let(::staDirectVideoCaptureDate)
                }
                thumbnail = largestEmbeddedJpeg(header)
                staDirectMetadataDiagnostics.putIfAbsent(
                    "video",
                    ("direct VIDEO handle=0x%08X header=%dB tail=%dB date=%s thumbnail=%dB").format(
                        handle,
                        header.size,
                        tailBytes,
                        captureDate ?: "<none>",
                        thumbnail?.size ?: 0,
                    ),
                )
            }
        }
        val dateStem = captureDate?.filter(Char::isDigit)?.take(14)
        val fileName = originalFileName?.takeIf { original ->
            original.substringAfterLast('.', missingDelimiterValue = "")
                .equals(extension.removePrefix("."), ignoreCase = true)
        } ?: buildString {
            append("ZTransfer_")
            if (!dateStem.isNullOrEmpty()) append(dateStem).append('_')
            append("%08X".format(handle))
            append(extension)
        }
        return StaDirectObjectHeader(
            file = CameraFileInfo(
                handle = handle,
                size = size,
                fileName = fileName,
                captureDate = captureDate,
            ),
            thumbnail = thumbnail,
            successful = true,
        )
    }

    /** Reuses a retained session prefix and asks the camera only for the still-missing suffix. */
    private fun readStaDirectPrefixInternal(handle: Int, targetBytes: Int): ByteArray? {
        if (targetBytes <= 0) return null
        val retained = staDirectRecentHeaders[handle]
        if (retained != null && retained.size >= targetBytes) return retained
        val offset = retained?.size ?: 0
        val missing = targetBytes - offset
        val chunk = readStaDirectPartialInternal(handle, offset.toLong(), missing) ?: return null
        return if (retained == null) chunk else retained + chunk
    }

    private data class StaDirectExifResult(
        val captureDate: String?,
        val thumbnail: ByteArray?,
        val error: String?,
    )

    private fun parseStaDirectExif(bytes: ByteArray, isRaw: Boolean): StaDirectExifResult {
        var temp: File? = null
        return try {
            val exif = if (isRaw) {
                File.createTempFile("sta_direct_", ".nef", context.cacheDir).also {
                    temp = it
                    it.writeBytes(bytes)
                }.let(::ExifInterface)
            } else {
                ExifInterface(ByteArrayInputStream(bytes))
            }
            val captureDate = staDirectCaptureDate(
                sequenceOf(
                    ExifInterface.TAG_DATETIME_ORIGINAL,
                    ExifInterface.TAG_DATETIME_DIGITIZED,
                    ExifInterface.TAG_DATETIME,
                ).mapNotNull(exif::getAttribute).firstOrNull(String::isNotBlank),
            )
            StaDirectExifResult(
                captureDate = captureDate,
                thumbnail = if (exif.hasThumbnail()) exif.thumbnailBytes else null,
                error = null,
            )
        } catch (error: Exception) {
            StaDirectExifResult(null, null, error.javaClass.simpleName)
        } finally {
            temp?.delete()
        }
    }

    /** Must be called while [ioMutex] is held. */
    private fun readStaDirectPartialInternal(
        handle: Int,
        offset: Long,
        maxSize: Int,
    ): ByteArray? {
        if (maxSize <= 0) return null
        sendCmd(
            PtpConstants.NK_GET_PARTIAL_OBJECT_EX,
            handle,
            (offset and 0xFFFFFFFFL).toInt(),
            (offset ushr 32).toInt(),
            maxSize,
            0,
        )
        val (response, data) = recvRespWithPayload()
        return data?.takeIf { response == PtpConstants.RESPONSE_OK && it.isNotEmpty() }
    }

    /** Must be called while [ioMutex] is held; reads only an MPF-indexed secondary JPEG. */
    private fun readStaDirectJpegMpfPreviewInternal(handle: Int): ByteArray? {
        if (staDirectJpegMpfPreviews[handle].isNullOrEmpty()) {
            cacheStaDirectObjectHeader(
                handle,
                readStaDirectObjectHeaderInternal(handle, requireJpegPreviewIndex = true),
            )
        }
        val references = staDirectJpegMpfPreviews[handle].orEmpty()
        if (references.isEmpty()) {
            if (PhotoGenerationProbe.enabled) {
                PhotoGenerationProbe.note(
                    "STA-PREVIEW",
                    "MPF handle=0x%08X candidates=<none>".format(handle),
                )
            }
            return null
        }

        for (reference in references) {
            val startedAt = SystemClock.elapsedRealtime()
            val bytes = readStaDirectPartialInternal(
                handle = handle,
                offset = reference.offset,
                maxSize = reference.length,
            )
            val isCompleteJpeg = bytes?.let {
                it.size == reference.length && it.size >= 4 &&
                    it[0] == 0xFF.toByte() && it[1] == 0xD8.toByte() &&
                    it[it.lastIndex - 1] == 0xFF.toByte() && it[it.lastIndex] == 0xD9.toByte()
            } ?: false
            val bounds = bytes?.takeIf { isCompleteJpeg }?.let { jpeg ->
                BitmapFactory.Options().also { options ->
                    options.inJustDecodeBounds = true
                    BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, options)
                }
            }
            val validPreview = bytes?.takeIf {
                isCompleteJpeg && (bounds?.outWidth ?: 0) > 0 && (bounds?.outHeight ?: 0) > 0
            }
            if (PhotoGenerationProbe.enabled) {
                PhotoGenerationProbe.note(
                    "STA-PREVIEW",
                    ("MPF handle=0x%08X type=0x%06X range=%d+%d bytes=%d jpeg=%s " +
                        "dimensions=%dx%d networkMs=%d").format(
                        handle,
                        reference.imageType,
                        reference.offset,
                        reference.length,
                        bytes?.size ?: 0,
                        isCompleteJpeg,
                        bounds?.outWidth ?: 0,
                        bounds?.outHeight ?: 0,
                        SystemClock.elapsedRealtime() - startedAt,
                    ),
                )
            }
            if (validPreview != null) return validPreview
        }
        return null
    }

    /** Must be called while [ioMutex] is held; invoked only for a visible RAW thumbnail. */
    private fun readStaDirectRawThumbnailInternal(file: CameraFileInfo): ByteArray? {
        fun readReference(reference: NefPreviewReference): ByteArray? =
            readStaDirectPartialInternal(
                handle = file.handle,
                offset = reference.offset,
                maxSize = reference.length,
            )?.takeIf { bytes ->
                bytes.size >= 2 &&
                    bytes[0] == 0xFF.toByte() &&
                    bytes[1] == 0xD8.toByte()
            }

        // Parser order is largest-first for full-screen preview; the grid should transfer the
        // smallest available embedded JPEG to minimize camera IO and decode work.
        staDirectRawPreviews[file.handle]?.lastOrNull()?.let { reference ->
            val cachedResult = readReference(reference)
            if (PhotoGenerationProbe.enabled) {
                PhotoGenerationProbe.note(
                    "STA-THUMB",
                    "RAW handle=0x%08X source=cached range=%d+%d requiredPrefix=%d thumbnail=%dB"
                        .format(
                            file.handle,
                            reference.offset,
                            reference.length,
                            reference.offset + reference.length,
                            cachedResult?.size ?: 0,
                        ),
                )
            }
            return cachedResult
        }

        // After one NEF establishes the embedded grid-JPEG offset, later files from the same
        // camera/session can skip the unused TIFF prefix. The bounded margin absorbs normal JPEG
        // size variation; a missing SOI/EOI simply falls through to the proven prefix parser.
        staDirectRawThumbnailHint?.let { hint ->
            val available = file.size - hint.offset
            val plan = if (hint.offset >= 0L) {
                staDirectRawThumbnailProbePlan(available, hint.length)
            } else {
                null
            }
            if (plan != null) {
                var chunk = readStaDirectPartialInternal(
                    handle = file.handle,
                    offset = hint.offset,
                    maxSize = plan.initialBytes,
                )
                val probeSteps = ArrayList<Int>(2)
                if (chunk != null) probeSteps += chunk.size
                var localReference = chunk?.let(::largestEmbeddedJpegRange)
                if (chunk != null && localReference == null &&
                    chunk.size < plan.maximumBytes
                ) {
                    val tail = readStaDirectPartialInternal(
                        handle = file.handle,
                        offset = hint.offset + chunk.size,
                        maxSize = plan.maximumBytes - chunk.size,
                    )
                    if (tail != null) {
                        chunk += tail
                        probeSteps += chunk.size
                        localReference = largestEmbeddedJpegRange(chunk)
                    }
                }
                if (chunk != null && localReference != null) {
                    val result = chunk.copyOfRange(
                        localReference.offset.toInt(),
                        localReference.offset.toInt() + localReference.length,
                    )
                    val absoluteReference = NefPreviewReference(
                        offset = hint.offset + localReference.offset,
                        length = localReference.length,
                    )
                    staDirectRawThumbnailHint = absoluteReference
                    staDirectRawPreviews[file.handle] = listOf(absoluteReference)
                    if (PhotoGenerationProbe.enabled) {
                        PhotoGenerationProbe.note(
                            "STA-THUMB",
                            ("RAW handle=0x%08X source=hint probeSteps=%s range=%d+%d " +
                                "thumbnail=%dB").format(
                                file.handle,
                                probeSteps.joinToString(","),
                                absoluteReference.offset,
                                    absoluteReference.length,
                                    result.size,
                                ),
                        )
                    }
                    return result
                }
            }
        }

        val maximumProbeBytes = minOf(
            file.size,
            STA_DIRECT_RAW_PROBE_PREFIX_BYTES.last().toLong(),
        ).toInt()
        if (maximumProbeBytes <= 0) return null

        // Allocate only the current step. Most Z30 NEFs expose the preview index inside 256 KiB;
        // reserving the full 16 MiB cap for every visible cell causes avoidable GC pauses.
        val cachedPrefix = staDirectRecentHeaders[file.handle]
        val reusedPrefixBytes = minOf(cachedPrefix?.size ?: 0, maximumProbeBytes)
        var accumulated = ByteArray(
            maxOf(
                minOf(STA_DIRECT_RAW_PROBE_PREFIX_BYTES.first(), maximumProbeBytes),
                reusedPrefixBytes,
            ),
        )
        cachedPrefix?.copyInto(accumulated, endIndex = reusedPrefixBytes)
        var loadedBytes = reusedPrefixBytes
        val probeSteps = ArrayList<Int>()
        var discoveredReference: NefPreviewReference? = null
        var discoveredReferences: List<NefPreviewReference> = emptyList()
        var previewReferenceFound = false
        var source = "none"
        var result: ByteArray? = null

        for (configuredTarget in STA_DIRECT_RAW_PROBE_PREFIX_BYTES) {
            val target = minOf(configuredTarget, maximumProbeBytes)
            if (accumulated.size < target) accumulated = accumulated.copyOf(target)
            val missing = target - loadedBytes
            if (missing > 0) {
                val chunk = readStaDirectPartialInternal(
                    handle = file.handle,
                    offset = loadedBytes.toLong(),
                    maxSize = missing,
                ) ?: break
                val accepted = minOf(chunk.size, maximumProbeBytes - loadedBytes)
                chunk.copyInto(
                    destination = accumulated,
                    destinationOffset = loadedBytes,
                    endIndex = accepted,
                )
                loadedBytes += accepted
            }
            rememberStaDirectPrefix(file.handle, accumulated, loadedBytes)

            probeSteps += loadedBytes

            val indexedReferences = parseNefHeaderMetadata(
                bytes = accumulated,
                validLength = loadedBytes,
            ).previews
            val indexedReference = indexedReferences.lastOrNull()
            if (indexedReference != null) {
                previewReferenceFound = true
                val indexedResult = readReference(indexedReference)
                if (indexedResult != null) {
                    discoveredReference = indexedReference
                    discoveredReferences = indexedReferences
                    source = "ifd"
                    result = indexedResult
                    break
                }
            }

            val scannedReference = largestEmbeddedJpegRange(accumulated, loadedBytes)
            if (scannedReference != null) {
                previewReferenceFound = true
                discoveredReference = scannedReference
                discoveredReferences = listOf(scannedReference)
                source = "scan"
                result = accumulated.copyOfRange(
                    scannedReference.offset.toInt(),
                    scannedReference.offset.toInt() + scannedReference.length,
                )
                break
            }
            if (loadedBytes >= maximumProbeBytes || loadedBytes < target) break
        }

        if (discoveredReferences.isNotEmpty()) {
            staDirectRawPreviews[file.handle] = discoveredReferences
            if (source == "ifd") staDirectRawIndexedPreviews += file.handle
        }
        if (result != null && discoveredReference != null) {
            staDirectRawThumbnailHint = discoveredReference
        }
        // Repeating the exact same fully-read bounded prefix cannot reveal a different preview.
        // Cache only that deterministic miss; a short read, rejected command, or referenced JPEG
        // fetch failure remains retryable so transient transport trouble never becomes "no thumb".
        if (result == null && !previewReferenceFound && loadedBytes >= maximumProbeBytes) {
            staDirectNoThumbnail += file.handle
        }
        if (PhotoGenerationProbe.enabled) {
            val reference = discoveredReference
            PhotoGenerationProbe.note(
                "STA-THUMB",
                ("RAW handle=0x%08X source=%s probeSteps=%s candidates=%s range=%s " +
                    "requiredPrefix=%s thumbnail=%dB").format(
                        file.handle,
                        source,
                        probeSteps.joinToString(","),
                        discoveredReferences.take(4).joinToString(",") {
                            "${it.offset}+${it.length}"
                        }.ifEmpty { "<none>" },
                        reference?.let { "${it.offset}+${it.length}" } ?: "<none>",
                        reference?.let { (it.offset + it.length).toString() } ?: "<none>",
                        result?.size ?: 0,
                    ),
            )
        }
        return result
    }

    /** Must be called while [ioMutex] is held; selects the smallest indexed RAW preview that is FHD. */
    private fun readStaDirectRawPreviewInternal(file: CameraFileInfo): ByteArray? {
        fun readReference(reference: NefPreviewReference): ByteArray? =
            readStaDirectPartialInternal(
                handle = file.handle,
                offset = reference.offset,
                maxSize = reference.length,
            )?.takeIf { bytes ->
                bytes.size == reference.length &&
                    bytes.size >= 4 &&
                    bytes[0] == 0xFF.toByte() &&
                    bytes[1] == 0xD8.toByte() &&
                    bytes[bytes.lastIndex - 1] == 0xFF.toByte() &&
                    bytes[bytes.lastIndex] == 0xD9.toByte()
            }

        fun readIndexedPreview(
            references: List<NefPreviewReference>,
            source: String,
            probeSteps: List<Int> = emptyList(),
        ): ByteArray? {
            if (references.isEmpty()) return null
            // Nikon NEFs commonly index both an approximately 1620x1080 display JPEG and a much
            // larger embedded JPEG. Length order alone used to select the largest one, making the
            // Z30 transfer 2-3 MiB even though the smaller entry already satisfies FHD preview.
            // Try plausible display previews from smallest to largest, validate their dimensions,
            // and only advance when the candidate is genuinely below the preview requirement.
            val ordered = references.distinct().sortedBy(NefPreviewReference::length)
            val plausible = ordered.filter { it.length >= STA_DIRECT_RAW_FHD_MIN_BYTES }
                .ifEmpty { ordered }
            var largestValid: ByteArray? = null
            var largestDimensions = 0 to 0
            val startedAt = SystemClock.elapsedRealtime()
            for (reference in plausible) {
                val bytes = readReference(reference) ?: continue
                val bounds = BitmapFactory.Options().also { options ->
                    options.inJustDecodeBounds = true
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
                }
                if (bounds.outWidth <= 0 || bounds.outHeight <= 0) continue
                largestValid = bytes
                largestDimensions = bounds.outWidth to bounds.outHeight
                val longEdge = maxOf(bounds.outWidth, bounds.outHeight)
                if (longEdge >= STA_DIRECT_RAW_FHD_MIN_LONG_EDGE) {
                    if (PhotoGenerationProbe.enabled) {
                        PhotoGenerationProbe.note(
                            "STA-PREVIEW",
                            ("RAW handle=0x%08X source=%s probeSteps=%s candidates=%s " +
                                "selected=%d+%d dimensions=%dx%d bytes=%d networkMs=%d").format(
                                    file.handle,
                                    source,
                                    probeSteps.joinToString(",").ifEmpty { "<cached>" },
                                    references.take(4).joinToString(",") {
                                        "${it.offset}+${it.length}"
                                    },
                                    reference.offset,
                                    reference.length,
                                    bounds.outWidth,
                                    bounds.outHeight,
                                    bytes.size,
                                    SystemClock.elapsedRealtime() - startedAt,
                                ),
                        )
                    }
                    return bytes
                }
            }
            val fallback = largestValid ?: return null
            if (PhotoGenerationProbe.enabled) {
                PhotoGenerationProbe.note(
                    "STA-PREVIEW",
                    ("RAW handle=0x%08X source=%s candidates=%s fallbackDimensions=%dx%d " +
                        "bytes=%d networkMs=%d").format(
                            file.handle,
                            source,
                            references.take(4).joinToString(",") {
                                "${it.offset}+${it.length}"
                            },
                            largestDimensions.first,
                            largestDimensions.second,
                            fallback.size,
                            SystemClock.elapsedRealtime() - startedAt,
                        ),
                )
            }
            return fallback
        }

        // References parsed from the TIFF IFD describe all embedded previews and are sorted
        // largest-first. A grid scan may cache only the first small JPEG, so it is intentionally
        // not trusted here unless it was backed by the IFD index.
        if (file.handle in staDirectRawIndexedPreviews) {
            staDirectRawPreviews[file.handle]?.let { references ->
                readIndexedPreview(references, "indexed-cache")?.let { return it }
            }
        }

        val maximumProbeBytes = minOf(
            file.size,
            STA_DIRECT_RAW_PROBE_PREFIX_BYTES.last().toLong(),
        ).toInt()
        if (maximumProbeBytes <= 0) return null

        val cachedPrefix = staDirectRecentHeaders[file.handle]
        val reusedPrefixBytes = minOf(cachedPrefix?.size ?: 0, maximumProbeBytes)
        var accumulated = ByteArray(
            maxOf(
                minOf(STA_DIRECT_RAW_PROBE_PREFIX_BYTES.first(), maximumProbeBytes),
                reusedPrefixBytes,
            ),
        )
        cachedPrefix?.copyInto(accumulated, endIndex = reusedPrefixBytes)
        var loadedBytes = reusedPrefixBytes
        val probeSteps = ArrayList<Int>()
        var bestScanned: NefPreviewReference? = null

        for (configuredTarget in STA_DIRECT_RAW_PROBE_PREFIX_BYTES) {
            val target = minOf(configuredTarget, maximumProbeBytes)
            if (accumulated.size < target) accumulated = accumulated.copyOf(target)
            val missing = target - loadedBytes
            if (missing > 0) {
                val chunk = readStaDirectPartialInternal(
                    handle = file.handle,
                    offset = loadedBytes.toLong(),
                    maxSize = missing,
                ) ?: break
                val accepted = minOf(chunk.size, maximumProbeBytes - loadedBytes)
                chunk.copyInto(accumulated, destinationOffset = loadedBytes, endIndex = accepted)
                loadedBytes += accepted
            }
            rememberStaDirectPrefix(file.handle, accumulated, loadedBytes)
            probeSteps += loadedBytes

            val indexed = parseNefHeaderMetadata(accumulated, loadedBytes).previews
            if (indexed.isNotEmpty()) {
                staDirectRawPreviews[file.handle] = indexed
                staDirectRawIndexedPreviews += file.handle
                readIndexedPreview(indexed, "ifd", probeSteps)?.let { return it }
            }

            largestEmbeddedJpegRange(accumulated, loadedBytes)?.let { candidate ->
                val previous = bestScanned
                if (previous == null || candidate.length > previous.length) {
                    bestScanned = candidate
                }
            }
            if (loadedBytes >= maximumProbeBytes || loadedBytes < target) break
        }

        val reference = bestScanned ?: return null
        val end = reference.offset + reference.length
        if (end > loadedBytes) return null
        val result = accumulated.copyOfRange(reference.offset.toInt(), end.toInt())
        if (PhotoGenerationProbe.enabled) {
            PhotoGenerationProbe.note(
                "STA-PREVIEW",
                "RAW handle=0x%08X source=scan probeSteps=%s range=%d+%d bytes=%d".format(
                    file.handle,
                    probeSteps.joinToString(","),
                    reference.offset,
                    reference.length,
                    result.size,
                ),
            )
        }
        return result
    }

    /** Must be called while [ioMutex] is held; never reads the full video. */
    private fun readStaDirectVideoThumbnailInternal(file: CameraFileInfo): ByteArray? {
        val requestSize = minOf(
            file.size,
            STA_DIRECT_VIDEO_THUMBNAIL_PREFIX_BYTES.toLong(),
        ).toInt()
        val bytes = readStaDirectPartialInternal(file.handle, 0L, requestSize) ?: return null
        val embedded = largestEmbeddedJpeg(bytes)
        val result = embedded ?: extractVideoFrame(bytes, file.extension)
        // The same bounded prefix and decoder would produce the same miss on every recomposition.
        // A null partial read returned above and remains retryable; only a completed probe is cached.
        if (result == null && bytes.size == requestSize) staDirectNoThumbnail += file.handle
        if (PhotoGenerationProbe.enabled) {
            PhotoGenerationProbe.note(
                "STA-THUMB",
                "VIDEO handle=0x%08X prefix=%dB embedded=%dB thumbnail=%dB".format(
                    file.handle,
                    bytes.size,
                    embedded?.size ?: 0,
                    result?.size ?: 0,
                ),
            )
        }
        return result
    }

    private fun extractVideoFrame(bytes: ByteArray, extension: String): ByteArray? {
        val temp = File.createTempFile("sta_video_", extension, context.cacheDir)
        val retriever = MediaMetadataRetriever()
        return try {
            temp.writeBytes(bytes)
            retriever.setDataSource(temp.absolutePath)
            val bitmap = retriever.getFrameAtTime(0L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: return null
            try {
                ByteArrayOutputStream().use { output ->
                    if (bitmap.compress(Bitmap.CompressFormat.JPEG, 86, output)) {
                        output.toByteArray()
                    } else {
                        null
                    }
                }
            } finally {
                bitmap.recycle()
            }
        } catch (_: Exception) {
            null
        } finally {
            runCatching { retriever.release() }
            temp.delete()
        }
    }

    /**
     * 双卡 ObjectInfo 流式归并。每组 handle 已按各自卡内的新到旧排列；这里只为每张卡
     * 保留一个已读取的 head，用其真实 captureDate 选择全机下一条。因此不会先扫完一张卡，
     * 也不需要把全部 ObjectInfo 读完才显示。每个 handle 仍只请求一次，每次持锁最多
     * 读取 [batchSize] 条 ObjectInfo 便释放 [ioMutex]，与单卡枚举的通道占用粒度一致。
     */
    suspend fun streamMergedFileInfo(
        newestFirstHandlesByStorage: List<List<Int>>,
        batchSize: Int = 20,
        onBatch: suspend (List<CameraFileInfo>, Int, Int) -> Unit,
    ): Boolean = withContext(Dispatchers.IO) {
        require(batchSize > 0) { "batchSize must be positive" }
        val groups = newestFirstHandlesByStorage.filter { it.isNotEmpty() }
        if (groups.isEmpty()) return@withContext true

        val loadContext = coroutineContext
        val total = groups.sumOf { it.size }
        val cursors = IntArray(groups.size)
        val heads = MutableList<CameraFileInfo?>(groups.size) { null }
        var completed = 0
        var allObjectInfoSucceeded = true

        while (completed < total) {
            val requestedHandles = ArrayList<Int>(batchSize)
            val observedFiles = ArrayList<CameraFileInfo>(batchSize)
            val probeStartedAtMs = if (FileOrderProbe.enabled) SystemClock.elapsedRealtime() else 0L
            val completedBeforeBatch = completed

            val output = ioMutex.withLock {
                var objectInfoRequests = 0
                buildList {
                    while (size < batchSize && completed < total) {
                        groups.indices.forEach { groupIndex ->
                            if (heads[groupIndex] != null) return@forEach
                            val handles = groups[groupIndex]
                            while (cursors[groupIndex] < handles.size) {
                                if (objectInfoRequests >= batchSize) return@forEach
                                loadContext.ensureActive()
                                val handle = handles[cursors[groupIndex]++]
                                objectInfoRequests++
                                requestedHandles += handle
                                val result = getObjectInfoInternal(handle)
                                val file = result.file
                                if (!result.successful) allObjectInfoSucceeded = false
                                if (file == null) {
                                    completed++
                                } else {
                                    observedFiles += file
                                    heads[groupIndex] = file
                                    break
                                }
                            }
                        }

                        // 还有一张卡的下一个文件尚未读到时，不能拿其它卡的旧 head 先输出，
                        // 否则跨卡顺序失去依据。请求预算用完就先释放锁，下批补齐 head。
                        val hasUnresolvedGroup = groups.indices.any { groupIndex ->
                            heads[groupIndex] == null &&
                                cursors[groupIndex] < groups[groupIndex].size
                        }
                        if (hasUnresolvedGroup) break

                        val selected = selectNewestFileHeadIndex(heads) ?: break
                        add(checkNotNull(heads[selected]))
                        heads[selected] = null
                        completed++
                    }
                }
            }

            if (FileOrderProbe.enabled && requestedHandles.isNotEmpty()) {
                FileOrderProbe.recordObjectInfoBatch(
                    requestedHandles = requestedHandles,
                    files = observedFiles,
                    elapsedMs = SystemClock.elapsedRealtime() - probeStartedAtMs,
                )
            }
            if (output.isNotEmpty()) {
                onBatch(output, completed, total)
            } else if (completed == completedBeforeBatch && requestedHandles.isEmpty()) {
                error("Merged ObjectInfo scan made no progress")
            }
        }
        allObjectInfoSucceeded
    }

    internal data class ObjectInfoResult(
        val file: CameraFileInfo?,
        /** false 只表示 PTP/载荷失败；成功返回的文件夹等非媒体对象仍为 true。 */
        val successful: Boolean,
    )

    internal fun getObjectInfoInternal(handle: Int): ObjectInfoResult {
        sendCmd(PtpConstants.GET_OBJECT_INFO, handle)
        val (respCode, data) = recvRespWithPayload()
        if (respCode != PtpConstants.RESPONSE_OK || data == null) {
            return ObjectInfoResult(null, false)
        }
        val parsed = parsePtpObjectInfo(handle, data) ?: return ObjectInfoResult(null, false)
        // 关联对象（0x3001 = 文件夹）不是文件，一律不收录：常见机型的全量枚举可能不含它，
        // 但换卡/目录滚动时相机新建文件夹会带 ObjectAdded 事件，实时新增路径必须拦住，
        // 否则列表会冒出一个 0 字节的"100NIKON"条目。
        if (parsed.isAssociation) return ObjectInfoResult(null, true)
        // PTP ObjectInfo 的大小字段是 32 位无符号；>4GB 的对象（长视频）相机报 0xFFFFFFFF（未知）。
        // ProtectionStatus(偏移 6,u16) 与文件同载荷,解析零额外流量。
        //（ObjectInfo 里还有两组刻意不用的字段:SequenceNumber(48)——机型可能恒填 0、
        // 语义不统一,连拍检测走"文件编号 + 秒级时间戳"的自有算法(computeBurstHandles);
        // ImagePixWidth/Height(26/30)——竖拍存的也是传感器原生横向像素,方向只在
        // EXIF Orientation 里且依赖机内"自动旋转图像"设置,判不出构图。）
        return ObjectInfoResult(
            file = CameraFileInfo(
                handle = parsed.handle,
                size = parsed.size,
                fileName = checkNotNull(parsed.fileName),
                captureDate = parsed.captureDate,
                isProtected = parsed.isProtected,
                storageIds = if (parsed.storageId == 0 || parsed.storageId == -1) {
                    emptySet()
                } else {
                    setOf(parsed.storageId)
                },
            ),
            successful = parsed.identityComplete,
        )
    }

    data class DownloadProgress(
        val downloaded: Long,
        val total: Long,
        val bytesPerSecond: Long,
    )

    /** 查询 >4GB 文件的真实大小；仅由下载事务在相机通道保护内调用。 */
    private fun getObjectSizeInternal(handle: Int): Long? {
        sendCmd(PtpConstants.NK_GET_OBJECT_SIZE, handle)
        val (respCode, data) = recvRespWithPayload()
        if (respCode != PtpConstants.RESPONSE_OK || data == null || data.size < 8) {
            log { "GetObjectSize failed: resp=0x${respCode.toString(16)}" }
            return null
        }
        val size = data.getLongLE(0)
        log { "GetObjectSize handle=$handle size=$size" }
        return if (size > 0) size else null
    }

    /** 单文件下载完成后的统计；速度由保存层按同一端到端时间范围计算。 */
    data class DownloadStats(
        val bytes: Long,
        /** 本次实际从相机读取的字节数，不包含续传前已经存在的部分。 */
        val transferredBytes: Long,
        /** 本文件进入协议下载流程的单调时钟时间戳（包含块间让路时间）。 */
        val startedAtElapsedMs: Long,
        /** Fresh downloads retain a bounded JPEG prefix so export can parse camera EXIF directly. */
        val headerPrefix: ByteArray? = null,
    )

    /**
     * 下载文件到 [output]。[totalSize] 为 ObjectInfo 中的文件大小（0/SIZE_UNKNOWN=未知）；
     * [resumeOffset] 非零时从该偏移续传（调用方须已把 output 定位到该偏移）。
     * [preferHighThroughputAtStart] 在首个文件数据命令前仅取值一次，之后页面切换不会改变当前文件。
     * [captureHeader] 在新文件传输时保留有限的文件头，供效果图导出复用；不会额外发起相机请求。
     *
     * 两条数据相位路径共用同一个 [pump] 循环，只是驱动它的命令不同：
     * - 分块（GetPartialObjectEx）：浏览模式的 Wi-Fi 已知大小文件，以及高吞吐模式下的
     *   大文件/续传；每块是完整 PTP 事务，块间可供 FHD / EXIF 插入。
     * - 全量（GetObject）：高吞吐模式的普通新文件，或分块不支持/大小未知时的回退。
     *
     * 续传是一等契约：若请求了 resumeOffset 但走不了分块（相机不支持 / 大小未知），
     * 绝不用"从 0 全量"去填一个已定位到偏移的流（会写出错位的损坏文件），而是抛
     * [ResumeUnavailableException] 让调用方删半成品重下。
     */
    suspend fun downloadToFile(
        handle: Int,
        output: OutputStream,
        onProgress: ((DownloadProgress) -> Unit)? = null,
        resumeOffset: Long = 0L,
        totalSize: Long = 0L,
        preferHighThroughputAtStart: () -> Boolean = { false },
        captureHeader: Boolean = false,
    ): Result<DownloadStats> = ioGate.withDownloadActivity {
        withContext(Dispatchers.IO) {
            val scope = this
            var totalDownloaded = resumeOffset
            // A resumed file already has bytes on disk; only fresh downloads can capture a
            // complete header without another camera request. Keep the prefix bounded and release
            // it with DownloadStats after the export task receives its parsed snapshot.
            val headerCapture = if (captureHeader && resumeOffset == 0L) {
                ByteArrayOutputStream(EXIF_HEADER_CAPTURE_BYTES)
            } else {
                null
            }
            // 从任务真正进入协议层开始计时；相机准备、分块事务、写入，以及分块之间为
            // FHD / EXIF 让路的时间都属于用户实际等待时间，实时速度必须使用这条时间线。
            val startTime = android.os.SystemClock.elapsedRealtime()
            var lastProgressTime = startTime

            fun buildStats(): DownloadStats {
                return DownloadStats(
                    bytes = totalDownloaded,
                    transferredBytes = transferredBytesThisAttempt(totalDownloaded, resumeOffset),
                    startedAtElapsedMs = startTime,
                    headerPrefix = headerCapture?.toByteArray()?.takeIf { it.isNotEmpty() },
                )
            }

            fun progressSnapshot(total: Long, now: Long) =
                DownloadProgress(
                    downloaded = totalDownloaded,
                    total = total,
                    bytesPerSecond = endToEndBytesPerSecond(
                        transferredBytes = transferredBytesThisAttempt(totalDownloaded, resumeOffset),
                        elapsedMs = now - startTime,
                    ),
                )

            fun emitProgress(total: Long, force: Boolean = false) {
                val now = android.os.SystemClock.elapsedRealtime()
                if (force || now - lastProgressTime >= 200L) {
                    onProgress?.invoke(progressSnapshot(total, now))
                    lastProgressTime = now
                }
            }
            fun writeChunk(bytes: ByteArray, offset: Int, count: Int) {
                try {
                    output.write(bytes, offset, count)
                } catch (e: java.io.IOException) {
                    throw OutputWriteException(
                        context.getString(R.string.error_write_file, e.message),
                        e,
                    )
                }
                headerCapture?.let { capture ->
                    val remaining = EXIF_HEADER_CAPTURE_BYTES - capture.size()
                    if (remaining > 0) {
                        capture.write(bytes, offset, minOf(count, remaining))
                    }
                }
            }
            fun incomplete(got: Long, want: Long) =
                Result.failure<DownloadStats>(Exception(context.getString(R.string.error_incomplete_data, got, want)))
            fun failed(respCode: Int) =
                Result.failure<DownloadStats>(Exception(
                    context.getString(R.string.error_transfer_failed_reason, PtpConstants.translateResponse(context, respCode))))

            // 读取一个完整的 PTP 数据相位（直到并【消费掉】CMD_RESPONSE），data 段经 output 写出。
            // 返回 (响应码, 本相位写出的字节数, START_DATA 声明的长度或 -1)。
            // 循环到 CMD_RESPONSE 为止——END_DATA 只当作最后一个 data 包，响应包必被读走，
            // 不再遗留污染下一事务。本地写盘失败抛 OutputWriteException（由外层归为单文件失败）。
            fun pump(progressTotalHint: Long): Triple<Int, Long, Long> {
                usbPtp?.let { usb ->
                    val total = if (progressTotalHint > 0) progressTotalHint else 0L
                    val result = usb.receiveDataTo(
                        expectedTransactionId = tid,
                        onDataStart = { emitProgress(total, force = true) },
                    ) { bytes, offset, count ->
                        scope.ensureActive()
                        writeChunk(bytes, offset, count)
                        totalDownloaded += count
                        emitProgress(total)
                    }
                    return Triple(result.responseCode, result.written, result.expected)
                }

                var expected = -1L
                var written = 0L
                while (true) {
                    scope.ensureActive()
                    val packet = cmdReader.readPacketRaw(cmdInput!!)
                    val buf = packet.buffer
                    val len = packet.payloadLen
                    when (packet.type) {
                        PtpConstants.CMD_RESPONSE ->
                            return Triple(if (len >= 2) buf.getUShortLE(0) else 0, written, expected)
                        PtpConstants.START_DATA_PACKET -> {
                            expected = when {
                                len >= 12 -> buf.getLongLE(4)
                                len >= 8 -> buf.getIntLE(4).toLong() and 0xFFFFFFFFL
                                else -> 0L
                            }
                            val total = if (progressTotalHint > 0) progressTotalHint else expected
                            emitProgress(total, force = true)
                        }
                        PtpConstants.DATA_PACKET, PtpConstants.END_DATA_PACKET -> {
                            if (len > 4) {
                                writeChunk(buf, 4, len - 4)
                                written += len - 4
                                totalDownloaded += len - 4
                                val total = if (progressTotalHint > 0) progressTotalHint else expected
                                emitProgress(total)
                            }
                        }
                        PtpConstants.PING -> sendPong(cmdOutput)
                    }
                }
            }

            // 事务异常共用：发 Cancel 请求相机停发 → 收紧超时排空在途数据 → 保住连接或兜底断开。
            suspend fun abortActiveTransaction() {
                if (usbPtp != null) {
                    // An aborted transaction may stop in the middle of a single USB data container.
                    // The next 12 bytes are therefore not guaranteed to be a container header;
                    // closing is the only safe way to avoid reusing a desynchronised PTP stream.
                    closeQuietly()
                    return
                }
                try {
                    withContext(NonCancellable) {
                        sendCancel()
                        cmdSocket?.soTimeout = CANCEL_DRAIN_TIMEOUT_MS
                        if (drainCmdResponse(CANCEL_DRAIN_BUDGET)) {
                            cmdSocket?.soTimeout = SO_TIMEOUT_MS
                        } else {
                            log { "DL_ABORT drain budget exceeded, closing" }
                            closeQuietly()
                        }
                    }
                } catch (_: Exception) {
                    closeQuietly()
                }
            }

            // 一个完整下载事务的安全边界。任何异常若发生在数据相位内，都必须仍持有
            // 通道锁完成 Cancel/排空；否则下一条 FHD/EXIF 可能读到上一事务遗留的数据包。
            suspend fun <T> transferTransaction(block: suspend () -> T): T =
                ioGate.withTransferSlice {
                    try {
                        block()
                    } catch (e: Exception) {
                        abortActiveTransaction()
                        throw e
                    }
                }

            try {
                // 对 >4GB 文件（ObjectInfo 报 SIZE_UNKNOWN）用 GetObjectSize 取真实 64 位大小。
                var effectiveSize = totalSize
                if (shouldQueryTransferSize(totalSize)) {
                    val queriedSize = transferTransaction { getObjectSizeInternal(handle) }
                    effectiveSize = resolvedTransferSize(totalSize, queriedSize)
                    queriedSize?.takeIf { it > 0L }?.let {
                        log { "DL_SIZE resolved: $totalSize -> $it via GetObjectSize" }
                    }
                }
                val sizeKnown = isKnownTransferSize(effectiveSize)
                val preferHighThroughput = preferHighThroughputAtStart()
                // 浏览时 Wi-Fi 保持小分块让路；USB 及传输页可见时的 Wi-Fi 使用高吞吐策略。
                // 此处已经冻结本文件快照，页面切换不会中途换道。
                val usePartial = shouldUsePartialObjectDownload(
                    partialObjectSupported = partialObjectSupported,
                    effectiveSize = effectiveSize,
                    resumeOffset = resumeOffset,
                    isUsbConnection = usbPtp != null,
                    preferHighThroughput = preferHighThroughput,
                    forcePartial = staDirectObjectReadValidated,
                )

                fun noteStaDownload(message: String) {
                    if (staDirectObjectReadValidated && PhotoGenerationProbe.enabled) {
                        PhotoGenerationProbe.note("STA-DL", message)
                    }
                }
                noteStaDownload(
                    "begin handle=0x%08X size=%d resume=%d partial=%s throughput=%s".format(
                        handle,
                        effectiveSize,
                        resumeOffset,
                        usePartial,
                        preferHighThroughput,
                    ),
                )

                // 请求了续传却走不了分块：全量只能从 0 填，会写坏已定位的流。拒绝，让调用方重下。
                if (isResumeUnavailable(resumeOffset, usePartial)) {
                    return@withContext Result.failure(ResumeUnavailableException())
                }

                if (usePartial) {
                    // ===== 分块路径 =====
                    var offset = resumeOffset
                    var first = true
                    var fellBack = false
                    val chunkSize = downloadChunkSize(
                        effectiveSize = effectiveSize,
                        isUsbConnection = usbPtp != null,
                        preferHighThroughput = preferHighThroughput,
                    )
                    while (offset < effectiveSize) {
                        scope.ensureActive()
                        val reqSize = minOf(chunkSize, effectiveSize - offset).toInt()
                        log { "DL_CHUNK offset=$offset size=$reqSize" }
                        val (resp, got, chunkExpected) = transferTransaction {
                            sendCmd(PtpConstants.NK_GET_PARTIAL_OBJECT_EX, handle,
                                (offset and 0xFFFFFFFFL).toInt(),
                                (offset ushr 32).toInt(), reqSize, 0)
                            pump(effectiveSize)
                        }
                        log { "DL_CHUNK_RESP resp=0x${resp.toString(16)} got=$got" }

                        if (resp != PtpConstants.RESPONSE_OK) {
                            noteStaDownload(
                                "partial failed handle=0x%08X offset=%d response=0x%04X got=%d".format(
                                    handle,
                                    offset,
                                    resp,
                                    got,
                                ),
                            )
                        }
                        when (
                            classifyPartialObjectResponse(
                                responseCode = resp,
                                isFirstChunk = first,
                                receivedBytes = got,
                                resumeOffset = resumeOffset,
                            )
                        ) {
                            PartialObjectResponseAction.FALLBACK_TO_FULL_OBJECT -> {
                                partialObjectSupported = false
                                fellBack = true
                                log { "DL_PARTIAL unsupported, full fallback" }
                                break
                            }

                            PartialObjectResponseAction.FAIL ->
                                return@withContext failed(resp)

                            PartialObjectResponseAction.ACCEPT -> Unit
                        }
                        partialObjectSupported = true
                        // 逐块校验：声明长度与实收不符 = 短读，立即失败（不吞不跳）。
                        if (!isPartialChunkLengthComplete(got, chunkExpected)) {
                            return@withContext incomplete(got, chunkExpected)
                        }
                        // OK 但零字节：相机不再推进，避免死循环。
                        if (!hasPartialChunkProgress(got)) {
                            return@withContext incomplete(totalDownloaded, effectiveSize)
                        }
                        // 按【实收字节】推进，而非请求量——短读也不会跳过未收到的区间。
                        offset += got
                        first = false
                    }
                    if (!fellBack) {
                        // 全文件完整性：分块模式的最终防线（此前只有逐块校验）。
                        if (!isPartialDownloadComplete(totalDownloaded, effectiveSize)) {
                            return@withContext incomplete(totalDownloaded, effectiveSize)
                        }
                        noteStaDownload(
                            "complete handle=0x%08X bytes=%d".format(handle, totalDownloaded),
                        )
                        return@withContext Result.success(buildStats())
                    }
                    // fellBack：resumeOffset 必为 0，totalDownloaded 仍为 0，落入下方全量路径。
                }

                // ===== 全量路径（仅 resumeOffset==0：全新下载 或 分块不支持回退）=====
                val (resp, _, expected) = transferTransaction {
                    sendCmd(PtpConstants.GET_OBJECT, handle)
                    pump(if (sizeKnown) effectiveSize else 0L)
                }
                log { "DL_FULL resp=0x${resp.toString(16)} total=$totalDownloaded" }
                noteStaDownload(
                    "unexpected full-object handle=0x%08X response=0x%04X bytes=%d".format(
                        handle,
                        resp,
                        totalDownloaded,
                    ),
                )
                if (resp != PtpConstants.RESPONSE_OK) return@withContext failed(resp)
                // 相机异常提前结束数据阶段：声明大小与实收不符则判残缺。SIZE_UNKNOWN/未声明放行。
                if (!isFullObjectLengthComplete(totalDownloaded, expected)) {
                    return@withContext incomplete(totalDownloaded, expected)
                }
                Result.success(buildStats())
            } catch (e: CancellationException) {
                // 数据相位内的取消已由 transferTransaction 在持锁状态排空；块间取消没有
                // 在途协议数据，直接传播即可。
                throw e
            } catch (e: Exception) {
                if (staDirectObjectReadValidated && PhotoGenerationProbe.enabled) {
                    PhotoGenerationProbe.note(
                        "STA-DL",
                        "exception handle=0x%08X type=%s message=%s".format(
                            handle,
                            e.javaClass.simpleName,
                            e.message.orEmpty(),
                        ),
                    )
                }
                Result.failure(e)
            }
        }
    }

    /**
     * 关闭会话与连接。为 suspend 并纳入 [ioMutex] + IO 线程：
     * - 避免在主线程发起 socket 写导致 NetworkOnMainThreadException；
     * - 与进行中的命令/下载互斥，消除并发读写同一 socket 的竞态；
     * - 用 NonCancellable 保证即使调用方作用域已取消也能完成清理。
     */
    suspend fun close() = withContext(NonCancellable + Dispatchers.IO) {
        ioMutex.withLock {
            // 仅在会话确实打开时才发送 CloseSession，否则握手中途失败时会空等响应。
            if (sessionOpen) {
                try {
                    sendCmd(PtpConstants.CLOSE_SESSION)
                    recvResp()
                } catch (_: Exception) {}
            }
            closeQuietly()
        }
    }

    private fun closeQuietly() {
        sessionOpen = false
        try { usbPtp?.close() } catch (_: Exception) {}
        usbPtp = null
        connectedUsbManager = null
        connectedUsbDevice = null
        try { cmdInput?.close() } catch (_: Exception) {}
        try { cmdSocket?.close() } catch (_: Exception) {}
        try { evtInput?.close() } catch (_: Exception) {}
        try { evtSocket?.close() } catch (_: Exception) {}
        evtThread?.interrupt()
        evtThread = null
        ptpIpEventChannel.close()
    }

    /**
     * 临时修改命令通道读超时，返回原值。只允许已持有 [ioMutex] 的
     * 协议序列使用，避免其它事务观察到临时超时值。
     */
    internal fun setCommandReadTimeout(timeoutMs: Int): Int {
        usbPtp?.let {
            val previous = it.readTimeoutMs
            it.readTimeoutMs = timeoutMs.coerceAtLeast(1)
            return previous
        }
        val socket = cmdSocket ?: throw java.io.EOFException(context.getString(R.string.connection_lost))
        val previous = socket.soTimeout
        socket.soTimeout = timeoutMs.coerceAtLeast(1)
        return previous
    }

    /** 恢复 [setCommandReadTimeout] 保存的超时；连接已关闭时由调用方忽略异常。 */
    internal fun restoreCommandReadTimeout(timeoutMs: Int) {
        usbPtp?.let {
            it.readTimeoutMs = timeoutMs.coerceAtLeast(1)
            return
        }
        cmdSocket?.soTimeout = timeoutMs
    }

    /**
     * 命令包读取超时后不得继续复用该 PTP/IP 流：PacketReader 可能已读了
     * 半个包，迟到响应也会被下一事务误认。调用方必须已持有 [ioMutex]。
     */
    internal fun abortProtocolTransport() {
        closeQuietly()
    }

    /**
     * Replays the verified Nikon PC/STA ordering. A successful storage probe proves that the
     * camera is already in browsing mode. Only a rejected probe is allowed to enter pairing;
     * querying DeviceInfo unconditionally breaks browsing on some firmware versions.
     */
    private fun initializeStaBrowsingSession(
        allowPairing: Boolean,
        exploreAlbumAccess: Boolean,
        forceProfilePairing: Boolean,
        onConnectingStarted: (() -> Unit)?,
        onPairingStarted: (() -> Unit)?,
    ) {
        sendCmd(NIKON_COMPATIBILITY_INIT)
        val (compatibilityResponse, _) = recvRespWithPayload()
        staDiagnosticLines += "GetEventEx(0x941C)=${hexResponse(compatibilityResponse)}"
        if (compatibilityResponse != PtpConstants.RESPONSE_OK) {
            throw java.io.IOException(
                "Nikon STA initialization failed: 0x${compatibilityResponse.toString(16)}",
            )
        }

        sendCmd(PtpConstants.GET_STORAGE_IDS)
        val (storageResponse, storageData) = recvRespWithPayload()
        staStorageProbeReached = true
        val initialStorageIds = parsePtpUInt32Array(storageData).orEmpty()
        staDiagnosticLines +=
            "GetStorageIDs=${hexResponse(storageResponse)} ids=${formatStorageIds(initialStorageIds)}"
        if (shouldForceStaProfilePairing(
                storageResponse = storageResponse,
                forceProfilePairing = forceProfilePairing,
                allowPairing = allowPairing,
                protocolPairingMarkerExists = hasCompletedStaPairing(),
            )
        ) {
            // Z30 exposes full storage temporarily while the computer profile wizard is still
            // waiting for host pairing. Finish that one-time pairing first; otherwise the camera
            // never saves/completes the reusable profile and this apparent album success only
            // tests the pre-pairing loophole again.
            staDiagnosticLines += "state=FORCED_PROFILE_PAIRING"
            onPairingStarted?.invoke()
            completeInitialPairing()
            throw PairingCompletedException()
        }
        // A paired WTU session may expose a real StorageID while GetObjectHandles still contains
        // only the upload queue. During exploration, StorageIDs alone are therefore not proof of
        // full-card browsing; continue through handle and application-mode probes.
        if (hasUsableStaAlbumStorage(storageResponse, initialStorageIds) &&
            !exploreAlbumAccess
        ) {
            onConnectingStarted?.invoke()
            prefetchedStorageIds = initialStorageIds
            staAlbumAccessValidated = true
            staDiagnosticLines += "result=FULL_ALBUM_BASELINE"
            return
        }

        sendCmd(PtpConstants.GET_DEVICE_INFO)
        val (deviceInfoResponse, deviceInfoData) = recvRespWithPayload()
        val operations = if (
            deviceInfoResponse == PtpConstants.RESPONSE_OK && deviceInfoData != null
        ) {
            runCatching { cacheDeviceInfo(deviceInfoData).operations }.getOrDefault(emptySet())
        } else {
            emptySet()
        }
        staDiagnosticLines +=
            "GetDeviceInfo=${hexResponse(deviceInfoResponse)} operations=${operations.size}"
        if (isStaPairingOnlyOperationSet(operations) && allowPairing) {
            staDiagnosticLines += "state=PAIRING_REQUIRED"
            onPairingStarted?.invoke()
            completeInitialPairing()
            throw PairingCompletedException()
        }
        // Only now has the camera proved that this session does not require pairing. Publishing
        // CONNECTING earlier makes a stale app-side profile flash CONNECTING before PAIRING.
        onConnectingStarted?.invoke()

        // Some paired/newer Nikon bodies expose application-mode switching. Probe it only on the
        // explicit STA compatibility path; AP and the normal successful STA album path never execute
        // these commands. A failed probe restores mode 0 before the transport is closed.
        if (exploreAlbumAccess) {
            if (hasUsableStaAlbumStorage(storageResponse, initialStorageIds) &&
                validateStaObjectAccess("baseline", initialStorageIds)
            ) {
                prefetchedStorageIds = initialStorageIds
                staAlbumAccessValidated = true
                staDiagnosticLines += if (staDirectObjectReadValidated) {
                    "result=FULL_ALBUM_DIRECT_OBJECT_READ"
                } else {
                    "result=FULL_ALBUM_OBJECTINFO_VALIDATED"
                }
                return
            }

            sendCmd(NIKON_CHANGE_APPLICATION_MODE, 1)
            val applicationModeResponse = recvResp()
            staDiagnosticLines +=
                "ChangeApplicationMode(1)=${hexResponse(applicationModeResponse)}"
            if (applicationModeResponse == PtpConstants.RESPONSE_OK) {
                sendCmd(NIKON_COMPATIBILITY_INIT)
                val (modeCompatibilityResponse, _) = recvRespWithPayload()
                staDiagnosticLines +=
                    "mode:GetEventEx=${hexResponse(modeCompatibilityResponse)}"

                sendCmd(PtpConstants.GET_STORAGE_IDS)
                val (modeStorageResponse, modeStorageData) = recvRespWithPayload()
                val modeStorageIds = parsePtpUInt32Array(modeStorageData).orEmpty()
                staDiagnosticLines +=
                    "mode:GetStorageIDs=${hexResponse(modeStorageResponse)} " +
                        "ids=${formatStorageIds(modeStorageIds)}"
                if (hasUsableStaAlbumStorage(modeStorageResponse, modeStorageIds) &&
                    validateStaObjectAccess("application-mode", modeStorageIds)
                ) {
                    prefetchedStorageIds = modeStorageIds
                    staAlbumAccessValidated = true
                    staDiagnosticLines += "result=FULL_ALBUM_APPLICATION_MODE"
                    return
                }

                // Best-effort rollback: this probe must not leave the camera in remote mode when
                // it did not unlock album access.
                runCatching {
                    sendCmd(NIKON_CHANGE_APPLICATION_MODE, 0)
                    val rollbackResponse = recvResp()
                    staDiagnosticLines +=
                        "ChangeApplicationMode(0)=${hexResponse(rollbackResponse)}"
                }
            }
        }
        staDiagnosticLines += "result=FULL_ALBUM_UNAVAILABLE"
        throw java.io.IOException(
            if (staEmptyObjectListObserved && !staObjectHandlesObserved) {
                context.getString(R.string.sta_camera_no_media)
            } else {
                "STA album access unavailable (${hexResponse(storageResponse)})"
            },
        )
    }

    /** Validates full-card browsing with bounded samples; one AccessDenied rejects the route. */
    private fun validateStaObjectAccess(label: String, storageIds: List<Int>): Boolean {
        sendCmd(PtpConstants.GET_OBJECT_HANDLES, -1, -1, 0)
        val (handlesResponse, handlesData) = recvRespWithPayload()
        val handles = parsePtpUInt32Array(handlesData).orEmpty()
        staObjectHandlesObserved = staObjectHandlesObserved || handles.isNotEmpty()
        staEmptyObjectListObserved = staEmptyObjectListObserved ||
            (handlesResponse == PtpConstants.RESPONSE_OK &&
                handlesData?.size == 4 && handlesData.getIntLE(0) == 0)
        staDiagnosticLines +=
            "$label:GetObjectHandles(*)=${hexResponse(handlesResponse)} count=${handles.size}"
        if (handlesResponse != PtpConstants.RESPONSE_OK || handles.isEmpty()) return false

        val sampleIndexes = listOf(0, handles.lastIndex / 2, handles.lastIndex).distinct()
        val responses = ArrayList<String>(sampleIndexes.size)
        var allAccessible = true
        sampleIndexes.forEach { index ->
            val handle = handles[index]
            sendCmd(PtpConstants.GET_OBJECT_INFO, handle)
            val (response, data) = recvRespWithPayload()
            val accessible = response == PtpConstants.RESPONSE_OK && (data?.size ?: 0) >= 53
            if (!accessible) allAccessible = false
            responses += "0x%08X:%s/%dB".format(
                handle,
                hexResponse(response),
                data?.size ?: 0,
            )
        }
        staDiagnosticLines += "$label:GetObjectInfo samples=[${responses.joinToString(",")}]"
        if (!allAccessible) {
            // Last bounded escape-hatch probe: metadata may be denied while thumbnail/partial
            // reads are accidentally still available. Never request the full object here.
            val handle = handles.first()
            sendCmd(PtpConstants.GET_THUMB, handle)
            val (thumbResponse, thumbData) = recvRespWithPayload()

            sendCmd(PtpConstants.NK_GET_OBJECT_SIZE, handle)
            val (sizeResponse, sizeData) = recvRespWithPayload()

            sendCmd(PtpConstants.NK_GET_PARTIAL_OBJECT_EX, handle, 0, 0, STA_SAMPLE_BYTES, 0)
            val (partialResponse, partialData) = recvRespWithPayload()

            val head = partialData?.take(4)?.joinToString("") {
                "%02X".format(it.toInt() and 0xFF)
            }.orEmpty()
            staDiagnosticLines +=
                ("$label:direct-read handle=0x%08X " +
                    "thumb=%s/%dB size=%s/%dB partial=%s/%dB head=%s").format(
                        handle,
                        hexResponse(thumbResponse),
                        thumbData?.size ?: 0,
                        hexResponse(sizeResponse),
                        sizeData?.size ?: 0,
                        hexResponse(partialResponse),
                        partialData?.size ?: 0,
                        head,
                    )
            val directSize = if (sizeResponse == PtpConstants.RESPONSE_OK &&
                sizeData != null && sizeData.size >= 8
            ) sizeData.getLongLE(0) else 0L
            val directAccessible = directSize > 0L &&
                partialResponse == PtpConstants.RESPONSE_OK &&
                partialData != null && partialData.isNotEmpty()
            if (directAccessible) {
                staDirectObjectReadValidated = true
                rememberValidatedStaObjectHandles(storageIds, handles)
                staDiagnosticLines += "$label:access=DIRECT_OBJECT_READ"
                return true
            }
        }
        if (allAccessible) rememberValidatedStaObjectHandles(storageIds, handles)
        return allAccessible
    }

    private fun rememberValidatedStaObjectHandles(storageIds: List<Int>, handles: List<Int>) {
        val usable = storageIds.filter { it != 0 && it != -1 }
        if (usable.size != 1) return
        val storageId = usable.single()
        val queryStorageId = if (storageId and 0xFFFF == 0) -1 else storageId
        prefetchedStaObjectHandles = PrefetchedStaObjectHandles(queryStorageId, handles)
    }

    /** Completes the one-time Nikon PC-mode pairing and leaves reconnection to the caller. */
    private fun completeInitialPairing() {
        sendCmd(PtpConstants.NK_PAIRING_QUERY)
        val (queryResponse, _) = recvRespWithPayload()
        if (queryResponse != PtpConstants.RESPONSE_OK) {
            throw java.io.IOException(
                "Nikon pairing query failed: 0x${queryResponse.toString(16)}",
            )
        }

        sendCmd(PtpConstants.NK_PAIRING_RESULT, PtpConstants.RESPONSE_OK)
        val resultResponse = recvResp()
        if (resultResponse != PtpConstants.RESPONSE_OK) {
            throw java.io.IOException(
                "Nikon pairing result failed: 0x${resultResponse.toString(16)}",
            )
        }
        // Persist at the authoritative OK response, before waiting for the optional pacing event.
        // This closes the process-death window without changing the camera-side protocol sequence.
        markStaPairingCompleted()

        // The OK response is authoritative. The following DeviceInfoChanged event is useful for
        // pacing but is missing on some firmware, so timeout only affects the reconnect delay.
        val previousTimeout = evtSocket?.soTimeout ?: SO_TIMEOUT_MS
        val deadlineNanos = System.nanoTime() + PAIRING_EVENT_TIMEOUT_MS * 1_000_000L
        try {
            while (System.nanoTime() < deadlineNanos) {
                val remainingMs = ((deadlineNanos - System.nanoTime()) / 1_000_000L)
                    .coerceAtLeast(1L)
                evtSocket?.soTimeout = remainingMs.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                val packet = evtReader.readPacket(evtInput!!)
                if (packet.type == PtpConstants.PING) {
                    sendPong(evtSocket?.getOutputStream())
                    continue
                }
                val eventCode = if (
                    packet.type == PtpConstants.EVENT && (packet.payload?.size ?: 0) >= 2
                ) {
                    packet.payload!!.getUShortLE(0)
                } else {
                    0
                }
                if (eventCode == PtpConstants.EVENT_DEVICE_INFO_CHANGED) break
            }
        } catch (_: Exception) {
            // Pairing was already acknowledged; reconnect below even without the optional event.
        } finally {
            evtSocket?.soTimeout = previousTimeout
        }

        runCatching {
            sendCmd(PtpConstants.CLOSE_SESSION)
            recvResp()
            sessionOpen = false
        }
    }

    private fun persistentInitiatorId(preferenceKey: String = "initiator_id"): ByteArray {
        val preferences = context.applicationContext.getSharedPreferences(
            PTPIP_IDENTITY_PREFERENCES,
            Context.MODE_PRIVATE,
        )
        var id = preferences.getString(preferenceKey, null)
        if (id == null || !id.matches(Regex("[0-9a-f]{16}"))) {
            id = ByteArray(8)
                .also { java.security.SecureRandom().nextBytes(it) }
                .joinToString("") { "%02x".format(it.toInt() and 0xFF) }
            preferences.edit().putString(preferenceKey, id).commit()
        }
        return id.toByteArray(Charsets.US_ASCII)
    }

    private fun hasCompletedStaPairing(): Boolean = responderGuid?.let { cameraGuid ->
        context.applicationContext.getSharedPreferences(
            PTPIP_IDENTITY_PREFERENCES,
            Context.MODE_PRIVATE,
        ).getBoolean("$STA_PAIRING_MARKER_PREFIX$cameraGuid", false)
    } ?: false

    private fun markStaPairingCompleted() {
        val cameraGuid = responderGuid ?: return
        context.applicationContext.getSharedPreferences(
            PTPIP_IDENTITY_PREFERENCES,
            Context.MODE_PRIVATE,
        )
            .edit()
            .putBoolean("$STA_PAIRING_MARKER_PREFIX$cameraGuid", true)
            .commit()
    }

    private fun hexResponse(response: Int): String =
        "0x%04X".format(response and 0xFFFF)

    private fun formatStorageIds(ids: List<Int>): String =
        "${ids.size}[${ids.joinToString(",") { "0x%08X".format(it) }}]"

    /** Existing camera-hotspot InitCommandRequest; keep byte-for-byte behavior unchanged. */
    private fun makeInitReq(): ByteArray {
        val hostname = "NikonPTP"
        val guid = ByteArray(16).also { java.security.SecureRandom().nextBytes(it) }
        return PtpIpProtocolCodec.encodeLegacyInitCommandRequest(guid, hostname)
    }

    /** Nikon PC/STA mode needs a stable initiator and the standard 32-bit protocol version. */
    private fun makeStaInitReq(identity: StaInitiatorIdentity): ByteArray {
        val guid = persistentInitiatorId(
            when (identity) {
                StaInitiatorIdentity.PAIRED_COMPUTER -> "initiator_id"
                StaInitiatorIdentity.ALBUM_EXPLORER -> "sta_album_explorer_id"
            },
        )
        return PtpIpProtocolCodec.encodeStandardInitCommandRequest(guid, "ZTransfer")
    }

    internal fun sendCmd(code: Int, vararg params: Int) {
        usbPtp?.let { usb ->
            usb.sendCommand(code, nextTid(), params)
            return
        }
        val pkt = PtpIpProtocolCodec.encodeCommandRequest(
            operationCode = code,
            transactionId = nextTid(),
            parameters = params,
        )
        cmdOutput?.write(pkt)
        cmdOutput?.flush()
    }

    /**
     * 带 data-out 数据阶段的命令（如 SetDevicePropValue）：CMD_REQUEST(dataPhase=2)
     * + Start-Data + End-Data（小载荷一包发完）。仅遥控实验（RemoteLab.kt）使用，
     * 正式传输路径没有 data-out 场景。
     */
    internal fun sendCmdWithData(code: Int, data: ByteArray, vararg params: Int) {
        val t = nextTid()
        usbPtp?.let { usb ->
            usb.sendCommand(code, t, params)
            usb.sendData(code, t, data)
            return
        }
        val pkt = PtpIpProtocolCodec.encodeCommandWithData(
            operationCode = code,
            transactionId = t,
            data = data,
            parameters = params,
        )
        cmdOutput?.write(pkt)
        cmdOutput?.flush()
    }

    /** 应答 PING。命令通道传 [cmdOutput]，事件通道传其自身输出流（各自独立，无并发冲突）。 */
    private fun sendPong(output: OutputStream?) {
        val pong = PtpIpPacketCodec.encode(PtpConstants.PONG)
        output?.write(pong)
        output?.flush()
    }

    /** 等待并返回响应码。中途丢弃的数据包（如 keepalive 的 GetStorageIds 数据段）用 raw 读，不逐包分配。 */
    private fun recvResp(): Int {
        usbPtp?.let { return it.receiveResponse(tid) }
        while (true) {
            val packet = cmdReader.readPacketRaw(cmdInput!!)
            when (packet.type) {
                PtpConstants.CMD_RESPONSE ->
                    return PtpIpProtocolCodec.decodeResponseCode(packet.buffer, packet.payloadLen)
                PtpConstants.PING -> sendPong(cmdOutput)
            }
        }
    }

    internal fun recvRespWithPayload(): Pair<Int, ByteArray?> {
        usbPtp?.let { return it.receiveResponseWithPayload(tid) }
        // 用 ByteArrayOutputStream 累积多包数据，避免 responseData + data 的 O(n²) 复制。
        var buffer: java.io.ByteArrayOutputStream? = null
        while (true) {
            val packet = cmdReader.readPacket(cmdInput!!)
            when (packet.type) {
                PtpConstants.CMD_RESPONSE -> {
                    val respCode = packet.payload?.let { PtpIpProtocolCodec.decodeResponseCode(it) } ?: 0
                    return respCode to buffer?.toByteArray()
                }
                PtpConstants.DATA_PACKET, PtpConstants.END_DATA_PACKET -> {
                    val p = packet.payload
                    if (p != null && p.size > 4) {
                        val out = buffer ?: java.io.ByteArrayOutputStream().also { buffer = it }
                        out.write(p, 4, p.size - 4)
                    }
                }
                PtpConstants.PING -> sendPong(cmdOutput)
            }
        }
    }

    private fun drainCmdResponse() {
        // 读取并丢弃直到本次传输的 CMD_RESPONSE。成功路径此时只剩 CMD_RESPONSE；
        // 用 raw 读避免逐包分配。
        while (true) {
            val packet = cmdReader.readPacketRaw(cmdInput!!)
            if (packet.type == PtpConstants.CMD_RESPONSE) return
            if (packet.type == PtpConstants.PING) sendPong(cmdOutput)
        }
    }

    /**
     * 带预算的排空（取消路径专用）：读取并丢弃直到 CMD_RESPONSE，返回 true；
     * 累计排空超过 [maxBytes] 仍没等到响应（机型不理会 Cancel、还在发整个文件）返回 false。
     */
    private fun drainCmdResponse(maxBytes: Long): Boolean {
        var drained = 0L
        while (drained <= maxBytes) {
            val packet = cmdReader.readPacketRaw(cmdInput!!)
            when (packet.type) {
                PtpConstants.CMD_RESPONSE -> return true
                PtpConstants.PING -> sendPong(cmdOutput)
                else -> drained += packet.payloadLen
            }
        }
        return false
    }

    /** PTP/IP Cancel 包：请求相机中止当前事务（[tid] 为最后发出的事务号）的数据阶段。 */
    private fun sendCancel() {
        val pkt = PtpIpProtocolCodec.encodeCancelRequest(tid)
        cmdOutput?.write(pkt)
        cmdOutput?.flush()
    }

    /** 读取小端无符号 16 位，返回 0..65535，避免高位错误码 (0xAxxx) 被符号扩展。 */
    private fun ByteArray.getUShortLE(offset: Int): Int {
        return (this[offset].toInt() and 0xFF) or ((this[offset + 1].toInt() and 0xFF) shl 8)
    }

    private fun ByteArray.getIntLE(offset: Int): Int {
        return (this[offset].toInt() and 0xFF) or
                ((this[offset + 1].toInt() and 0xFF) shl 8) or
                ((this[offset + 2].toInt() and 0xFF) shl 16) or
                ((this[offset + 3].toInt() and 0xFF) shl 24)
    }

    private fun ByteArray.getLongLE(offset: Int): Long {
        return (getIntLE(offset).toLong() and 0xFFFFFFFFL) or (getIntLE(offset + 4).toLong() shl 32)
    }
}
