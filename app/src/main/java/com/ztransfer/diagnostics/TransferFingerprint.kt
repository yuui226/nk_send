package com.ztransfer.diagnostics

import java.security.MessageDigest

/** Whole-file byte count and SHA-256. Used to accept a Harmony publish, not to write a report. */
internal class TransferFingerprint {
    private val digest: MessageDigest = MessageDigest.getInstance("SHA-256")
    private var bytes: Long = 0L

    fun update(buffer: ByteArray, offset: Int, count: Int) {
        require(offset >= 0 && count >= 0 && offset <= buffer.size - count)
        if (count == 0) return
        digest.update(buffer, offset, count)
        bytes += count.toLong()
    }

    fun finish(): FingerprintResult =
        FingerprintResult(bytes, digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) })
}

internal data class FingerprintResult(
    val bytes: Long,
    val sha256: String,
)
