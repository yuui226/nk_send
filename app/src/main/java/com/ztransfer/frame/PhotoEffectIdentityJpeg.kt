package com.ztransfer.frame

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/** Stores an effect fingerprint in JPEG metadata without changing its image data. */
internal object PhotoEffectIdentityJpeg {
    private val magic = "ZTransfer.PhotoEffectIdentity\u0000v1\u0000".toByteArray(Charsets.US_ASCII)
    private const val IDENTITY_LENGTH = 64
    private const val MAX_HEADER_BYTES = 4 * 1024 * 1024

    /**
     * Inserts APP15 after the start marker, or after a leading APP0 to preserve JFIF ordering.
     * At most one APP0 segment is buffered; image data passes through unchanged. Closing the
     * returned stream also closes [output].
     */
    fun outputStream(output: OutputStream, identity: String): OutputStream {
        require(isIdentity(identity)) { "Expected a lowercase SHA-256 fingerprint" }
        val payload = magic + identity.toByteArray(Charsets.US_ASCII)
        val segmentLength = payload.size + 2
        val prefix = byteArrayOf(
            0xff.toByte(), 0xd8.toByte(), 0xff.toByte(), 0xef.toByte(),
            (segmentLength ushr 8).toByte(), segmentLength.toByte(),
        ) + payload
        return IdentityOutputStream(output, prefix)
    }

    /**
     * Reads only JPEG metadata, stopping before image data. Malformed or incomplete metadata
     * returns null; I/O errors propagate. The caller retains ownership of [input].
     */
    fun read(input: InputStream): String? {
        val reader = HeaderReader(input)
        if (reader.read() != 0xff || reader.read() != 0xd8) return null
        while (true) {
            if (reader.read() != 0xff) return null
            var marker: Int
            do {
                marker = reader.read()
            } while (marker == 0xff)
            when (marker) {
                -1, 0x00, 0xd8, 0xd9, 0xda -> return null
                0x01, in 0xd0..0xd7 -> continue // Standalone markers have no length.
            }
            if (marker < 0xc0) return null
            val high = reader.read()
            val low = reader.read()
            if (high < 0 || low < 0) return null
            val payloadLength = (high shl 8 or low) - 2
            if (payloadLength < 0) return null
            if (marker == 0xef && payloadLength == magic.size + IDENTITY_LENGTH) {
                val payload = ByteArray(payloadLength)
                if (!reader.readFully(payload)) return null
                if (magic.indices.all { payload[it] == magic[it] }) {
                    val identity = String(payload, magic.size, IDENTITY_LENGTH, Charsets.US_ASCII)
                    return identity.takeIf(::isIdentity)
                }
            } else if (!reader.skip(payloadLength)) {
                return null
            }
        }
    }

    private fun isIdentity(value: String): Boolean =
        value.length == IDENTITY_LENGTH && value.all { it in '0'..'9' || it in 'a'..'f' }

    private class IdentityOutputStream(
        private val output: OutputStream,
        private val prefix: ByteArray,
    ) : OutputStream() {
        private var header = ByteArray(6)
        private var headerBytes = 0
        private var headerTarget = 2
        private var headerWritten = false
        private var invalidHeader = false
        private var closed = false

        override fun write(value: Int) {
            ensureOpen()
            if (headerWritten) {
                output.write(value)
            } else {
                header[headerBytes++] = value.toByte()
                if (headerBytes == headerTarget) advanceHeader()
            }
        }

        override fun write(bytes: ByteArray, offset: Int, length: Int) {
            if (offset < 0 || length < 0 || offset > bytes.size - length) {
                throw IndexOutOfBoundsException()
            }
            ensureOpen()
            var start = offset
            val end = offset + length
            while (!headerWritten && start < end) {
                val count = minOf(headerTarget - headerBytes, end - start)
                bytes.copyInto(header, headerBytes, start, start + count)
                start += count
                headerBytes += count
                if (headerBytes == headerTarget) advanceHeader()
            }
            if (start < end) output.write(bytes, start, end - start)
        }

        override fun flush() {
            ensureOpen()
            output.flush()
        }

        override fun close() {
            if (closed) return
            closed = true
            val headerFailure = if (!headerWritten && !invalidHeader) {
                IOException("Incomplete JPEG header")
            } else null
            try {
                output.close()
            } catch (failure: IOException) {
                if (headerFailure == null) throw failure
                headerFailure.addSuppressed(failure)
            }
            if (headerFailure != null) throw headerFailure
        }

        private fun ensureOpen() {
            if (closed) throw IOException("Stream is closed")
            if (invalidHeader) throw IOException("Invalid JPEG header")
        }

        private fun advanceHeader() {
            when (headerTarget) {
                2 -> {
                    if (unsigned(0) != 0xff || unsigned(1) != 0xd8) invalidHeader()
                    headerTarget = 4
                }
                4 -> {
                    if (unsigned(2) == 0xff && unsigned(3) == 0xe0) {
                        headerTarget = 6
                    } else {
                        output.write(prefix + header.copyOfRange(2, 4))
                        headerWritten = true
                    }
                }
                6 -> {
                    val length = unsigned(4) shl 8 or unsigned(5)
                    if (length < 2) invalidHeader()
                    headerTarget = length + 4
                    if (headerTarget > header.size) header = header.copyOf(headerTarget)
                    if (headerBytes == headerTarget) writeAfterApp0()
                }
                else -> writeAfterApp0()
            }
        }

        private fun writeAfterApp0() {
            output.write(header, 0, headerBytes)
            output.write(prefix, 2, prefix.size - 2)
            headerWritten = true
        }

        private fun unsigned(index: Int): Int = header[index].toInt() and 0xff

        private fun invalidHeader(): Nothing {
            invalidHeader = true
            throw IOException("Invalid JPEG header")
        }
    }

    private class HeaderReader(private val input: InputStream) {
        private var remaining = MAX_HEADER_BYTES

        fun read(): Int {
            if (remaining == 0) return -1
            val value = input.read()
            if (value >= 0) remaining--
            return value
        }

        fun readFully(bytes: ByteArray): Boolean {
            if (bytes.size > remaining) return false
            var offset = 0
            while (offset < bytes.size) {
                val count = input.read(bytes, offset, bytes.size - offset)
                if (count < 0) return false
                if (count == 0) {
                    val value = read()
                    if (value < 0) return false
                    bytes[offset++] = value.toByte()
                } else {
                    remaining -= count
                    offset += count
                }
            }
            return true
        }

        fun skip(length: Int): Boolean {
            if (length > remaining) return false
            var left = length
            while (left > 0) {
                val skipped = input.skip(left.toLong()).toInt()
                if (skipped > 0) {
                    remaining -= skipped
                    left -= skipped
                } else {
                    if (read() < 0) return false
                    left--
                }
            }
            return true
        }
    }
}
