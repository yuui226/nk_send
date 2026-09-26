package com.ztransfer.protocol

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Fault injection into the already-received byte buffer, not a hardware reproduction.
 * Uses the real container parser/writer without opening an Android USB connection.
 */
class UsbPayloadIntegrityInvestigationTest {
    private fun container(type: Int, code: Int, tid: Int, payload: ByteArray): ByteArray =
        ByteBuffer.allocate(12 + payload.size).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(12 + payload.size); putShort(type.toShort()); putShort(code.toShort()); putInt(tid)
            put(payload)
        }.array()

    private fun bufferedTransport(bytes: ByteArray): UsbPtpConnection {
        val unsafeClass = Class.forName("sun.misc.Unsafe")
        val field = unsafeClass.getDeclaredField("theUnsafe").apply { isAccessible = true }
        val transport = unsafeClass.getMethod("allocateInstance", Class::class.java)
            .invoke(field.get(null), UsbPtpConnection::class.java) as UsbPtpConnection
        fun set(name: String, value: Any) {
            UsbPtpConnection::class.java.getDeclaredField(name).apply { isAccessible = true }.set(transport, value)
        }
        set("ioBuffer", ByteArray(256 * 1024))
        set("usbReadBuffer", bytes)
        set("bufferedReadEnd", bytes.size)
        return transport
    }

    @Test fun sameLengthZeroFilledPayloadIsNotDetectedByCurrentContainerChecks() {
        val original = ByteArray(6 * 1024 * 1024) { (it % 251 + 1).toByte() }
        val damaged = original.copyOf().apply { fill(0, 3 * 1024 * 1024, 3 * 1024 * 1024 + 268 * 1024) }
        val stream = container(2, PtpConstants.GET_OBJECT, 7, damaged) + container(3, PtpConstants.RESPONSE_OK, 7, byteArrayOf())
        val output = ByteArrayOutputStream()
        val result = bufferedTransport(stream).receiveDataTo(7) { bytes, offset, count -> output.write(bytes, offset, count) }
        assertEquals(PtpConstants.RESPONSE_OK, result.responseCode)
        assertEquals(original.size.toLong(), result.expected)
        assertEquals(original.size.toLong(), result.written)
        assertArrayEquals(damaged, output.toByteArray())
        assertFalse(original.contentEquals(output.toByteArray()))
    }

    @Test fun intactPayloadRemainsInOrderAcrossOutputBufferBoundaries() {
        val original = ByteArray(1024 * 1024 + 137) { (it % 251 + 1).toByte() }
        val stream = container(2, PtpConstants.GET_OBJECT, 8, original) + container(3, PtpConstants.RESPONSE_OK, 8, byteArrayOf())
        val output = ByteArrayOutputStream()
        bufferedTransport(stream).receiveDataTo(8) { bytes, offset, count -> output.write(bytes, offset, count) }
        assertArrayEquals(original, output.toByteArray())
    }
}
