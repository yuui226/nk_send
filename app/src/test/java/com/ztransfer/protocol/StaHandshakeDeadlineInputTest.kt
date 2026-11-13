package com.ztransfer.protocol

import java.io.ByteArrayInputStream
import java.io.InputStream
import java.net.SocketTimeoutException
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class StaHandshakeDeadlineInputTest {
    @Test fun repeatedSuccessfulReadsCannotRenewTheResponseBudget() {
        var now = 0L
        var reads = 0
        val timeouts = mutableListOf<Int>()
        val input = object : InputStream() {
            override fun read(): Int {
                reads++
                now += 400_000_000L
                return 0x5A
            }
        }
        val guarded = StaHandshakeDeadlineInput(input, 1_000, timeouts::add) { now }

        assertEquals(0x5A, guarded.read())
        assertEquals(0x5A, guarded.read())
        // Even a positive underlying result must be rejected if it arrives after the deadline.
        assertThrows(SocketTimeoutException::class.java) { guarded.read() }
        assertEquals(listOf(1_000, 600, 200), timeouts)
        assertThrows(SocketTimeoutException::class.java) { guarded.read() }
        assertEquals(3, reads) // Once expired, no further blocking read may begin.
    }

    @Test fun fragmentedBulkReadsUseOneBudgetAndKeepOffsets() {
        var now = 0L
        var reads = 0
        val timeouts = mutableListOf<Int>()
        val input = object : InputStream() {
            override fun read(): Int = error("Bulk reads should be delegated directly")
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                now += 100_000_000L
                buffer[offset] = (++reads).toByte()
                return 1
            }
        }
        val guarded = StaHandshakeDeadlineInput(input, 250, timeouts::add) { now }
        val bytes = ByteArray(6)

        assertEquals(1, guarded.read(bytes, 2, 4))
        assertEquals(1, guarded.read(bytes, 3, 3))
        assertThrows(SocketTimeoutException::class.java) { guarded.read(bytes, 4, 2) }
        assertEquals(listOf(250, 150, 50), timeouts)
        assertEquals(1.toByte(), bytes[2])
        assertEquals(2.toByte(), bytes[3])
        assertEquals(0.toByte(), bytes[0])
    }

    @Test fun aCompleteResponseImmediatelyBeforeTheDeadlineIsAccepted() {
        var now = 0L
        val bytes = byteArrayOf(0x01, 0x20)
        val input = object : ByteArrayInputStream(bytes) {
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                now = 4_999_999_999L
                return super.read(buffer, offset, length)
            }
        }
        val guarded = StaHandshakeDeadlineInput(input, 5_000, {}) { now }
        val response = ByteArray(2)
        assertEquals(2, guarded.read(response))
        assertArrayEquals(bytes, response)
        assertEquals(-1, guarded.read())

        now = 5_000_000_000L
        assertThrows(SocketTimeoutException::class.java) { guarded.read() }
    }

    @Test fun positiveSubMillisecondRemainderNeverDisablesTheSocketTimeout() {
        var now = 0L
        val timeouts = mutableListOf<Int>()
        val guarded = StaHandshakeDeadlineInput(
            ByteArrayInputStream(byteArrayOf(7)), 1, timeouts::add,
        ) { now }
        now = 999_999L
        assertEquals(7, guarded.read())
        assertEquals(listOf(1), timeouts)
    }

    @Test fun zeroLengthReadsAndArgumentValidationDoNotTouchTheTransport() {
        var now = 0L
        val guarded = StaHandshakeDeadlineInput(
            object : InputStream() {
                override fun read(): Int = error("Must not read the transport")
            },
            1,
            { error("Must not update the timeout") },
        ) { now }
        now = 2_000_000L // A no-op read remains a no-op even after the budget expires.
        val bytes = ByteArray(2)
        assertEquals(0, guarded.read(ByteArray(0)))
        assertEquals(0, guarded.read(bytes, bytes.size, 0))
        assertThrows(IndexOutOfBoundsException::class.java) { guarded.read(bytes, 3, 0) }
        assertThrows(IndexOutOfBoundsException::class.java) { guarded.read(bytes, -1, 0) }
        assertThrows(IndexOutOfBoundsException::class.java) { guarded.read(bytes, 0, -1) }
        assertThrows(IndexOutOfBoundsException::class.java) { guarded.read(bytes, Int.MAX_VALUE, 1) }
    }

    @Test fun availableAndCloseDelegateWithoutStartingARead() {
        var closed = false
        val input = object : ByteArrayInputStream(byteArrayOf(1, 2, 3)) {
            override fun close() { closed = true; super.close() }
        }
        val guarded = StaHandshakeDeadlineInput(input, 1_000, { error("No reads expected") }) { 0L }
        assertEquals(3, guarded.available())
        guarded.close()
        assertTrue(closed)
    }

    @Test fun theMonotonicClockMayCrossTheSignedLongBoundary() {
        var now = Long.MAX_VALUE - 500_000L
        val guarded = StaHandshakeDeadlineInput(ByteArrayInputStream(byteArrayOf(1)), 1, {}) { now }
        now += 999_999L
        assertEquals(1, guarded.read())
        now++
        assertThrows(SocketTimeoutException::class.java) { guarded.read() }
    }
}
