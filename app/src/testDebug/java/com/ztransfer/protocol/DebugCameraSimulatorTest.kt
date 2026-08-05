package com.ztransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.EOFException
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder

class DebugCameraSimulatorTest {
    @Test
    fun embeddedSimulatorCompletesHandshakeAndListsAllPhotos() {
        DebugCameraSimulator.start()
        val command = connectWithRetry()
        command.use { cmd ->
            writePacket(cmd, type = 1)
            val ack = readPacket(cmd.getInputStream())
            assertEquals(2, ack.type)
            val connectionNumber = ack.payload.intLe(0)

            connectWithRetry().use { event ->
                writePacket(event, type = 3, payload = le(4) { putInt(connectionNumber) })
                assertEquals(4, readPacket(event.getInputStream()).type)

                sendCommand(cmd, operation = 0x1002, transactionId = 0, connectionNumber)
                assertResponse(readPacket(cmd.getInputStream()), transactionId = 0)

                sendCommand(cmd, operation = 0x1004, transactionId = 1)
                val storage = readDataResponse(cmd, transactionId = 1)
                assertEquals(1, storage.intLe(0))
                assertEquals(0x00010001, storage.intLe(4))

                sendCommand(
                    cmd,
                    operation = 0x1007,
                    transactionId = 2,
                    0x00010001,
                    -1,
                    0
                )
                val handles = readDataResponse(cmd, transactionId = 2)
                assertEquals(36, handles.intLe(0))
                val firstHandle = handles.intLe(4)

                sendCommand(cmd, operation = 0x1008, transactionId = 3, firstHandle)
                val objectInfo = readDataResponse(cmd, transactionId = 3)
                assertEquals(0x3804, objectInfo.shortLe(4))
                assertEquals("ZSIM_0036.PNG", objectInfo.ptpString(52))

                sendCommand(cmd, operation = 0x100A, transactionId = 4, firstHandle)
                val thumbnail = readDataResponse(cmd, transactionId = 4)
                assertEquals("89504e47", thumbnail.take(4).joinToString("") {
                    "%02x".format(it)
                })
            }
        }
    }

    private fun connectWithRetry(): Socket {
        var lastError: Exception? = null
        repeat(100) {
            try {
                return Socket().apply {
                    soTimeout = 5_000
                    connect(InetSocketAddress("127.0.0.1", 15740), 500)
                }
            } catch (error: Exception) {
                lastError = error
                Thread.sleep(50)
            }
        }
        throw AssertionError("embedded simulator did not start", lastError)
    }

    private fun sendCommand(
        socket: Socket,
        operation: Int,
        transactionId: Int,
        vararg params: Int
    ) {
        writePacket(socket, type = 6, payload = le(10 + params.size * 4) {
            putInt(0)
            putShort(operation.toShort())
            putInt(transactionId)
            params.forEach(::putInt)
        })
    }

    private fun readDataResponse(socket: Socket, transactionId: Int): ByteArray {
        val input = socket.getInputStream()
        assertEquals(9, readPacket(input).type)
        val end = readPacket(input)
        assertEquals(12, end.type)
        assertEquals(transactionId, end.payload.intLe(0))
        assertResponse(readPacket(input), transactionId)
        return end.payload.copyOfRange(4, end.payload.size)
    }

    private fun assertResponse(packet: Packet, transactionId: Int) {
        assertEquals(7, packet.type)
        assertEquals(0x2001, packet.payload.shortLe(0))
        assertEquals(transactionId, packet.payload.intLe(2))
    }

    private data class Packet(val type: Int, val payload: ByteArray)

    private fun readPacket(input: InputStream): Packet {
        val header = input.readExact(8)
        val length = header.intLe(0)
        return Packet(header.intLe(4), input.readExact(length - 8))
    }

    private fun writePacket(socket: Socket, type: Int, payload: ByteArray = byteArrayOf()) {
        socket.getOutputStream().apply {
            write(le(8) { putInt(8 + payload.size); putInt(type) })
            write(payload)
            flush()
        }
    }

    private fun InputStream.readExact(size: Int): ByteArray {
        val data = ByteArray(size)
        var offset = 0
        while (offset < size) {
            val count = read(data, offset, size - offset)
            if (count < 0) throw EOFException()
            offset += count
        }
        return data
    }

    private fun ByteArray.intLe(offset: Int): Int =
        ByteBuffer.wrap(this, offset, 4).order(ByteOrder.LITTLE_ENDIAN).int

    private fun ByteArray.shortLe(offset: Int): Int =
        ByteBuffer.wrap(this, offset, 2).order(ByteOrder.LITTLE_ENDIAN).short.toInt() and 0xFFFF

    private fun ByteArray.ptpString(offset: Int): String {
        val chars = this[offset].toInt() and 0xFF
        return String(this, offset + 1, chars * 2, Charsets.UTF_16LE).trimEnd('\u0000')
    }

    private fun le(size: Int, fill: ByteBuffer.() -> Unit): ByteArray =
        ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN).apply(fill).array()
}
