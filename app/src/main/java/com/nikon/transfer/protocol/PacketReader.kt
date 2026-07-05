package com.nikon.transfer.protocol

import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

class PacketReader {
    companion object {
        const val HEADER_SIZE = 8
    }

    private var buffer = ByteArray(1024 * 1024) // 1MB initial

    data class Packet(val type: Int, val payload: ByteArray?)

    fun readPacket(input: InputStream): Packet {
        // 读取8字节头
        val header = readExactly(input, HEADER_SIZE)
        val length = header.getIntLE(0)
        val type = header.getIntLE(4)
        val payloadLen = length - HEADER_SIZE

        val payload = if (payloadLen > 0) {
            readExactly(input, payloadLen)
        } else {
            null
        }

        return Packet(type, payload)
    }

    private fun readExactly(input: InputStream, n: Int): ByteArray {
        if (n > buffer.size) {
            buffer = ByteArray(n)
        }
        var offset = 0
        while (offset < n) {
            val read = input.read(buffer, offset, n - offset)
            if (read == -1) throw java.io.EOFException("连接已断开")
            offset += read
        }
        return buffer.copyOf(n)
    }

    private fun ByteArray.getIntLE(offset: Int): Int {
        return (this[offset].toInt() and 0xFF) or
                ((this[offset + 1].toInt() and 0xFF) shl 8) or
                ((this[offset + 2].toInt() and 0xFF) shl 16) or
                ((this[offset + 3].toInt() and 0xFF) shl 24)
    }
}
