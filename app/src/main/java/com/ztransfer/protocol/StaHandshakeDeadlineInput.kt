package com.ztransfer.protocol

import java.io.InputStream
import java.net.SocketTimeoutException

/**
 * One absolute budget for a STA handshake response, including PINGs and fragmented packets.
 * The caller owns transport abortion and restoring the socket timeout after this response.
 * Not used for photo/video transfers, whose duration naturally exceeds handshake budgets.
 */
internal class StaHandshakeDeadlineInput(
    private val input: InputStream,
    timeoutMs: Int,
    private val setReadTimeout: (Int) -> Unit,
    private val nanoTime: () -> Long = System::nanoTime,
) : InputStream() {
    init { require(timeoutMs > 0) { "STA handshake deadline must be positive" } }

    private val deadlineNanos = nanoTime() + timeoutMs.toLong() * NANOS_PER_MILLISECOND

    override fun read(): Int {
        prepareRead()
        val value = input.read()
        remainingNanos()
        return value
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (offset < 0 || length < 0 || length > buffer.size - offset) {
            throw IndexOutOfBoundsException()
        }
        // InputStream requires a valid zero-length read to return 0 without touching the input.
        if (length == 0) return 0
        prepareRead()
        val count = input.read(buffer, offset, length)
        remainingNanos()
        return count
    }

    override fun available(): Int = input.available()

    override fun close() = input.close()

    private fun prepareRead() {
        val remaining = remainingNanos()
        // Round up: a positive sub-millisecond budget must never become the infinite timeout 0.
        val millis = (remaining + NANOS_PER_MILLISECOND - 1) / NANOS_PER_MILLISECOND
        setReadTimeout(millis.coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
    }

    private fun remainingNanos(): Long {
        // Subtraction also works across the signed nanoTime wrap boundary for our Int-ms budget.
        val remaining = deadlineNanos - nanoTime()
        if (remaining <= 0L) throw SocketTimeoutException("STA handshake response deadline exceeded")
        return remaining
    }

    private companion object {
        const val NANOS_PER_MILLISECOND = 1_000_000L
    }
}
