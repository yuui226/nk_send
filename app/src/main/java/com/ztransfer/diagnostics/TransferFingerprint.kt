package com.ztransfer.diagnostics

import java.io.OutputStream
import java.security.MessageDigest
import java.util.Collections

internal data class FingerprintResult(
    val bytes: Long,
    val sha256: String,
    val segments: List<String>,
    val segmentBytes: Int,
    val segmentsTruncated: Boolean
)

/** Produces a compact, stable reason suitable for transfer diagnostics. */
internal fun fingerprintDifference(expected: FingerprintResult, actual: FingerprintResult): String {
    if (expected.bytes != actual.bytes) {
        return "SIZE_MISMATCH expected=${expected.bytes} actual=${actual.bytes}"
    }
    if (expected.sha256 == actual.sha256) return "MATCH"

    // A bounded segment list cannot prove where a mismatch occurred after its final entry.
    if (expected.segmentsTruncated || actual.segmentsTruncated ||
        expected.segmentBytes != actual.segmentBytes
    ) {
        return "CONTENT_MISMATCH firstDifferentSegment=unknown offset=unknown"
    }
    val firstDifferent = expected.segments.indices.firstOrNull { index ->
        index >= actual.segments.size || expected.segments[index] != actual.segments[index]
    } ?: actual.segments.indices.firstOrNull { index -> index >= expected.segments.size }
    if (firstDifferent == null) {
        return "CONTENT_MISMATCH firstDifferentSegment=unknown offset=unknown"
    }
    return "CONTENT_MISMATCH firstDifferentSegment=$firstDifferent " +
        "offset=${firstDifferent.toLong() * expected.segmentBytes}"
}

/**
 * Computes fingerprints without retaining any source bytes. Segment hashes are bounded by
 * [maxSegments]; the whole-stream hash and byte count still cover all bytes after that limit.
 * Like MessageDigest and OutputStream, this class is intended for a single writer.
 */
internal class TransferFingerprint(
    private val segmentBytes: Int = 4 * 1024 * 1024,
    private val maxSegments: Int = 4096
) {
    init {
        require(segmentBytes > 0) { "segmentBytes must be positive" }
        require(maxSegments >= 0) { "maxSegments must not be negative" }
    }

    private val wholeDigest = MessageDigest.getInstance("SHA-256")
    private val segmentDigest = MessageDigest.getInstance("SHA-256")
    private val segments = ArrayList<String>(minOf(maxSegments, 16))
    private var bytes = 0L
    private var bytesInSegment = 0
    private var segmentsTruncated = false
    private var result: FingerprintResult? = null

    fun update(bytes: ByteArray, offset: Int, count: Int) {
        checkUpdateAllowed(bytes, offset, count)
        if (count == 0) return

        wholeDigest.update(bytes, offset, count)
        this.bytes += count.toLong()
        var cursor = offset
        var remaining = count
        while (remaining > 0 && segments.size < maxSegments) {
            val part = minOf(remaining, segmentBytes - bytesInSegment)
            segmentDigest.update(bytes, cursor, part)
            bytesInSegment += part
            cursor += part
            remaining -= part
            if (bytesInSegment == segmentBytes) {
                segments.add(segmentDigest.digest().toHex())
                bytesInSegment = 0
            }
        }
        if (remaining > 0) segmentsTruncated = true
    }

    fun finish(): FingerprintResult {
        result?.let { return it }
        if (bytesInSegment > 0) {
            segments.add(segmentDigest.digest().toHex())
            bytesInSegment = 0
        }
        return FingerprintResult(
            bytes = bytes,
            sha256 = wholeDigest.digest().toHex(),
            segments = Collections.unmodifiableList(ArrayList(segments)),
            segmentBytes = segmentBytes,
            segmentsTruncated = segmentsTruncated
        ).also { result = it }
    }

    /** Also used by the output wrapper to reject invalid writes before touching its delegate. */
    internal fun checkUpdateAllowed(bytes: ByteArray, offset: Int, count: Int) {
        check(result == null) { "Fingerprint has already been finished" }
        // Subtraction avoids offset + count overflowing for malformed callers.
        if (offset < 0 || count < 0 || offset > bytes.size || count > bytes.size - offset) {
            throw IndexOutOfBoundsException("offset=$offset, count=$count, size=${bytes.size}")
        }
    }
}

/**
 * Forwards the exact range synchronously and hashes it only after the delegate returns successfully.
 * A failed write is excluded, since OutputStream cannot report how many bytes it partially wrote.
 * Closing and flushing have the delegate's usual behavior; closing does not finalize the fingerprint.
 */
internal class FingerprintingOutputStream(
    private val delegate: OutputStream,
    private val fingerprint: TransferFingerprint
) : OutputStream() {
    private val singleByte = ByteArray(1)

    override fun write(value: Int) {
        singleByte[0] = value.toByte()
        write(singleByte, 0, 1)
    }

    override fun write(bytes: ByteArray) = write(bytes, 0, bytes.size)

    override fun write(bytes: ByteArray, offset: Int, count: Int) {
        fingerprint.checkUpdateAllowed(bytes, offset, count)
        delegate.write(bytes, offset, count)
        fingerprint.update(bytes, offset, count)
    }

    override fun flush() = delegate.flush()

    override fun close() = delegate.close()
}

private fun ByteArray.toHex(): String {
    val digits = "0123456789abcdef"
    val output = CharArray(size * 2)
    for (index in indices) {
        val value = this[index].toInt() and 0xff
        output[index * 2] = digits[value ushr 4]
        output[index * 2 + 1] = digits[value and 0x0f]
    }
    return String(output)
}
