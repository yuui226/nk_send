package com.ztransfer.protocol

import android.content.Context
import com.ztransfer.R
import java.io.InputStream

class PacketReader(private val context: Context) {
    companion object {
        const val HEADER_SIZE = 8
        // 包长上限：远大于任何真实 PTP/IP 包，仅用于拦截损坏/伪造的长度字段。
        // 不校验的话 length=0x7FFFFFFF 会直接按 2GB 分配缓冲抛 OutOfMemoryError
        //（Error 不会被上层 catch(Exception) 捕获，App 直接崩溃）；length<8 则会
        // 让后续读取错位，之后全是脏数据。越界按 IOException 处理，走断线重连。
        const val MAX_PACKET_SIZE = 256 * 1024 * 1024
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
        val length = readValidatedLength(input)
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
        val length = readValidatedLength(input)
        raw.type = headerBuf.getIntLE(4)
        raw.payloadLen = length - HEADER_SIZE
        if (raw.payloadLen > 0) {
            ensureCapacity(raw.payloadLen)
            readFully(input, buffer, raw.payloadLen)
        }
        raw.buffer = buffer
        return raw
    }

    /** 读包头并校验长度字段合理性；返回校验过的包长（含头），类型字段留在 [headerBuf] 中。 */
    private fun readValidatedLength(input: InputStream): Int {
        readFully(input, headerBuf, HEADER_SIZE)
        val length = headerBuf.getIntLE(0)
        if (length < HEADER_SIZE || length > MAX_PACKET_SIZE) {
            throw java.io.IOException(context.getString(R.string.error_bad_packet_length, length))
        }
        return length
    }

    private fun ensureCapacity(n: Int) {
        if (n > buffer.size) buffer = ByteArray(n)
    }

    private fun readFully(input: InputStream, dst: ByteArray, n: Int) {
        var offset = 0
        while (offset < n) {
            val read = input.read(dst, offset, n - offset)
            if (read == -1) throw java.io.EOFException(context.getString(R.string.connection_lost))
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
