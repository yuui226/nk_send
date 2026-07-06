package com.nikon.transfer.protocol

import java.io.InputStream

class PacketReader {
    companion object {
        const val HEADER_SIZE = 8
    }

    private var buffer = ByteArray(1024 * 1024) // 1MB initial
    private val headerBuf = ByteArray(HEADER_SIZE)
    private val raw = RawPacket()

    data class Packet(val type: Int, val payload: ByteArray?)

    /**
     * 零拷贝包：直接暴露内部共享缓冲区，避免每包分配。调用方必须在下一次 read 之前
     * 用完 [buffer] 中的数据（下载循环是读-写-读的串行流程，天然满足）。
     */
    class RawPacket {
        var type: Int = 0
        var payloadLen: Int = 0
        var buffer: ByteArray = EMPTY
        companion object { private val EMPTY = ByteArray(0) }
    }

    fun readPacket(input: InputStream): Packet {
        readFully(input, headerBuf, HEADER_SIZE)
        val length = headerBuf.getIntLE(0)
        val type = headerBuf.getIntLE(4)
        val payloadLen = length - HEADER_SIZE

        val payload = if (payloadLen > 0) {
            ensureCapacity(payloadLen)
            readFully(input, buffer, payloadLen)
            buffer.copyOf(payloadLen)
        } else {
            null
        }

        return Packet(type, payload)
    }

    /**
     * 读取一个包但不复制 payload —— 返回复用的 [RawPacket]（其 buffer 指向内部缓冲区）。
     * 仅用于下载热路径，避免每包一次全量分配+复制带来的 GC 压力。
     */
    fun readPacketRaw(input: InputStream): RawPacket {
        readFully(input, headerBuf, HEADER_SIZE)
        val length = headerBuf.getIntLE(0)
        raw.type = headerBuf.getIntLE(4)
        val payloadLen = length - HEADER_SIZE
        raw.payloadLen = if (payloadLen > 0) payloadLen else 0
        if (raw.payloadLen > 0) {
            ensureCapacity(raw.payloadLen)
            readFully(input, buffer, raw.payloadLen)
        }
        raw.buffer = buffer
        return raw
    }

    private fun ensureCapacity(n: Int) {
        if (n > buffer.size) buffer = ByteArray(n)
    }

    private fun readFully(input: InputStream, dst: ByteArray, n: Int) {
        var offset = 0
        while (offset < n) {
            val read = input.read(dst, offset, n - offset)
            if (read == -1) throw java.io.EOFException("连接已断开")
            offset += read
        }
    }

    private fun ByteArray.getIntLE(offset: Int): Int {
        return (this[offset].toInt() and 0xFF) or
                ((this[offset + 1].toInt() and 0xFF) shl 8) or
                ((this[offset + 2].toInt() and 0xFF) shl 16) or
                ((this[offset + 3].toInt() and 0xFF) shl 24)
    }
}
