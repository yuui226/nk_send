package com.ztransfer.protocol

import com.ztransfer.viewmodel.suffixedTransferFileName
import com.ztransfer.viewmodel.transferDestinationFolderName
import com.ztransfer.viewmodel.transferPartFileName

class PtpIpDataStart internal constructor(val transactionId: Int, val declaredBytes: Long)

/** Narrow Native entry points: platform code does I/O, existing shared functions decide policy. */
object PtpTransferBridge {
    const val ACCEPT = 0
    const val FALLBACK = 1
    const val FAIL = 2

    /** Android pump accepts both legacy 32-bit and standard 64-bit StartData length fields. */
    fun decodeStart(payload: ByteArray): PtpIpDataStart? {
        if (payload.size < 4) return null
        val length = when {
            payload.size >= 12 -> payload.readInt64LittleEndian(4)
            payload.size >= 8 -> payload.readUInt32LittleEndian(4)
            else -> 0L
        }
        return PtpIpDataStart(payload.readInt32LittleEndian(0), length)
    }

    fun objectSize(payload: ByteArray): Long =
        if (payload.size < 8) 0L else payload.readInt64LittleEndian(0).coerceAtLeast(0L)

    fun partialParameters(handle: Int, offset: Long, count: Long): IntArray? =
        if (offset < 0L || count !in 1..Int.MAX_VALUE.toLong()) null
        else intArrayOf(handle, offset.toInt(), (offset ushr 32).toInt(), count.toInt(), 0)

    fun knownSize(size: Long): Boolean = isKnownTransferSize(size)
    fun querySize(size: Long): Boolean = shouldQueryTransferSize(size)
    fun resolvedSize(declared: Long, queried: Long): Long = resolvedTransferSize(declared, queried.takeIf { it > 0L })

    /** support: -1 unknown, 0 unsupported, 1 supported; avoids nullable Boolean boxing in Swift. */
    fun usePartial(support: Int, size: Long, resume: Long, highThroughput: Boolean, forcePartial: Boolean): Boolean =
        shouldUsePartialObjectDownload(
            partialObjectSupported = when (support) { 0 -> false; 1 -> true; else -> null },
            effectiveSize = size, resumeOffset = resume, preferHighThroughput = highThroughput,
            forcePartial = forcePartial,
        )

    fun chunkSize(size: Long, highThroughput: Boolean): Long =
        downloadChunkSize(effectiveSize = size, preferHighThroughput = highThroughput)

    fun resumeUnavailable(offset: Long, partial: Boolean): Boolean = isResumeUnavailable(offset, partial)
    fun partialAction(code: Int, first: Boolean, received: Long, resume: Long): Int = when (
        classifyPartialObjectResponse(code, first, received, resume)
    ) {
        PartialObjectResponseAction.ACCEPT -> ACCEPT
        PartialObjectResponseAction.FALLBACK_TO_FULL_OBJECT -> FALLBACK
        PartialObjectResponseAction.FAIL -> FAIL
    }

    fun chunkComplete(received: Long, declared: Long): Boolean = isPartialChunkLengthComplete(received, declared)
    fun chunkProgress(received: Long): Boolean = hasPartialChunkProgress(received)
    fun partialComplete(received: Long, expected: Long): Boolean = isPartialDownloadComplete(received, expected)
    fun fullComplete(received: Long, declared: Long): Boolean = isFullObjectLengthComplete(received, declared)
    fun speed(bytes: Long, elapsedMs: Long): Long = endToEndBytesPerSecond(bytes, elapsedMs)

    fun destinationFolder(captureDate: String?, byDate: Boolean, dayKey: Int): String? =
        transferDestinationFolderName(captureDate, byDate, dayKey)
    fun partName(name: String, size: Long, captureDate: String?): String = transferPartFileName(name, size, captureDate)
    fun copyName(name: String, number: Int): String = suffixedTransferFileName(name, number)
}
