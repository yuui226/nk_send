package com.nikon.transfer.protocol

import com.nikon.transfer.BuildConfig
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder

class NikonCamera {
    private var cmdSocket: Socket? = null
    private var evtSocket: Socket? = null
    private var cmdInput: java.io.InputStream? = null
    private var evtInput: java.io.InputStream? = null
    private var cmdOutput: OutputStream? = null
    private var tid = 0
    private val cmdReader = PacketReader()
    private val evtReader = PacketReader()
    private var evtThread: Thread? = null
    private val ioMutex = Mutex()

    private companion object {
        const val TAG = "NikonTransfer"
    }

    /** 仅 debug 构建输出协议日志，避免 release 包泄露 handle/size 并拖慢热路径。 */
    private inline fun log(message: () -> String) {
        if (BuildConfig.DEBUG) android.util.Log.d(TAG, message())
    }

    private fun nextTid(): Int {
        tid++
        return tid
    }

    suspend fun connect(ip: String = PtpConstants.CAMERA_IP): Result<String> = withContext(Dispatchers.IO) {
        try {
            cmdSocket = Socket().apply {
                tcpNoDelay = true
                soTimeout = 60000
                connect(InetSocketAddress(ip, PtpConstants.PTP_PORT), 5000)
            }
            cmdInput = cmdSocket!!.getInputStream()
            cmdOutput = cmdSocket!!.getOutputStream()

            cmdOutput!!.write(makeInitReq())
            cmdOutput!!.flush()

            val ack = cmdReader.readPacket(cmdInput!!)
            if (ack.type != PtpConstants.INIT_CMD_ACK) {
                return@withContext Result.failure(Exception("握手失败: 非 ACK 响应"))
            }

            val payload = ack.payload ?: return@withContext Result.failure(Exception("握手失败: 空响应"))
            val sessionId = payload.getIntLE(0)
            val camName = if (payload.size > 20) {
                String(payload, 20, payload.size - 20, Charsets.UTF_16LE).trimEnd('\u0000')
            } else "Nikon"

            evtSocket = Socket().apply {
                soTimeout = 60000
                connect(InetSocketAddress(ip, PtpConstants.PTP_PORT), 5000)
            }
            evtInput = evtSocket!!.getInputStream()

            val evtInit = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN).apply {
                putInt(12)
                putInt(PtpConstants.INIT_EVT_REQ)
                putInt(sessionId)
            }.array()
            evtSocket!!.getOutputStream().write(evtInit)
            evtSocket!!.getOutputStream().flush()

            val evtAck = evtReader.readPacket(evtInput!!)
            if (evtAck.type != PtpConstants.INIT_EVT_ACK) {
                return@withContext Result.failure(Exception("事件握手失败"))
            }

            sendCmd(PtpConstants.OPEN_SESSION, sessionId)
            val resp = recvResp()
            if (resp.first != PtpConstants.RESPONSE_OK) {
                return@withContext Result.failure(Exception("OpenSession 失败: ${PtpConstants.translateResponse(resp.first)}"))
            }

            startEvtThread()

            Result.success(camName)
        } catch (e: Exception) {
            close()
            Result.failure(e)
        }
    }

    private fun startEvtThread() {
        evtThread = Thread {
            try {
                while (evtSocket?.isConnected == true) {
                    try {
                        evtReader.readPacket(evtInput!!)
                    } catch (_: Exception) {
                        break
                    }
                }
            } catch (_: Exception) {}
        }.apply {
            isDaemon = true
            name = "PTP-EvtThread"
            start()
        }
    }

    suspend fun getStorageIds(): List<Int> = ioMutex.withLock {
        withContext(Dispatchers.IO) {
            try {
                sendCmd(PtpConstants.GET_STORAGE_IDS)
                val (respCode, data) = recvRespWithPayload()
                if (respCode != PtpConstants.RESPONSE_OK || data == null || data.size < 4) {
                    return@withContext emptyList()
                }
                val count = data.getIntLE(0)
                (0 until count).map { data.getIntLE(4 + it * 4) }
            } catch (_: Exception) {
                emptyList()
            }
        }
    }

    suspend fun keepalive(): Boolean = ioMutex.withLock {
        withContext(Dispatchers.IO) {
            try {
                sendCmd(PtpConstants.GET_STORAGE_IDS)
                val resp = recvResp()
                resp.first == PtpConstants.RESPONSE_OK
            } catch (_: Exception) {
                false
            }
        }
    }

    suspend fun getObjectHandles(storageId: Int = -1): List<Int> = ioMutex.withLock {
        withContext(Dispatchers.IO) {
            try {
                sendCmd(PtpConstants.GET_OBJECT_HANDLES, storageId, -1, 0)
                val (respCode, data) = recvRespWithPayload()
                if (respCode != PtpConstants.RESPONSE_OK || data == null || data.size < 4) {
                    return@withContext emptyList()
                }
                val count = data.getIntLE(0)
                (0 until count).map { data.getIntLE(4 + it * 4) }
            } catch (_: Exception) {
                emptyList()
            }
        }
    }

    data class FileInfo(
        val handle: Int,
        val format: Int,
        val size: Long,
        val fileName: String,
        val captureDate: String?
    ) {
        val extension: String get() = fileName.substringAfterLast('.', "")
    }

    suspend fun getObjectInfo(handle: Int): FileInfo? = ioMutex.withLock {
        withContext(Dispatchers.IO) {
            try {
                getObjectInfoInternal(handle)
            } catch (_: Exception) {
                null
            }
        }
    }

    suspend fun getAllFileInfo(handles: List<Int>): List<FileInfo> = ioMutex.withLock {
        withContext(Dispatchers.IO) {
            handles.mapNotNull { handle ->
                try {
                    getObjectInfoInternal(handle)
                } catch (_: Exception) {
                    null
                }
            }
        }
    }

    suspend fun streamFileInfo(
        handles: List<Int>,
        batchSize: Int = 20,
        onBatch: suspend (List<FileInfo>, Int, Int) -> Unit
    ) = ioMutex.withLock {
        withContext(Dispatchers.IO) {
            val total = handles.size
            var loaded = 0
            handles.chunked(batchSize).forEach { batch ->
                val files = batch.mapNotNull { handle ->
                    try { getObjectInfoInternal(handle) } catch (_: Exception) { null }
                }
                loaded += files.size
                if (files.isNotEmpty()) {
                    onBatch(files, loaded, total)
                }
            }
        }
    }

    private fun getObjectInfoInternal(handle: Int): FileInfo? {
        sendCmd(PtpConstants.GET_OBJECT_INFO, handle)
        val (respCode, data) = recvRespWithPayload()
        if (respCode != PtpConstants.RESPONSE_OK || data == null || data.size < 53) {
            return null
        }

        val format = data.getUShortLE(4)
        val size = data.getIntLE(8).toLong() and 0xFFFFFFFFL
        val ext = PtpConstants.getExt(format)

        val nameLen = data[52].toInt() and 0xFF
        val fileName = if (nameLen > 0 && data.size >= 53 + nameLen * 2) {
            String(data, 53, nameLen * 2, Charsets.UTF_16LE).trimEnd('\u0000')
        } else {
            "DSC_%04d%s".format(handle and 0xFFFF, ext)
        }

        val dateOffset = 53 + nameLen * 2
        val captureDate = if (data.size > dateOffset) {
            try {
                val dateLen = data[dateOffset].toInt() and 0xFF
                if (dateLen > 0 && data.size >= dateOffset + 1 + dateLen * 2) {
                    val dateStr = String(data, dateOffset + 1, dateLen * 2, Charsets.UTF_16LE).trimEnd('\u0000')
                    if (dateStr.length >= 8) dateStr.substring(0, 8) else null
                } else null
            } catch (_: Exception) { null }
        } else null

        return FileInfo(handle, format, size, fileName, captureDate)
    }

    data class DownloadProgress(
        val downloaded: Long,
        val total: Long,
        val elapsed: Float
    )

    suspend fun downloadToFile(
        handle: Int,
        output: OutputStream,
        onProgress: ((DownloadProgress) -> Unit)? = null
    ): Result<Pair<Long, String?>> = ioMutex.withLock {
        withContext(Dispatchers.IO) {
            try {
                sendCmd(PtpConstants.GET_OBJECT, handle)

                var totalDownloaded = 0L
                var expected = 0L
                var first4: ByteArray? = null
                val startTime = System.currentTimeMillis()
                var lastProgressTime = startTime

                while (true) {
                    // 协作式取消：在每个包边界检查，使 cancelTransfer() 能及时中断
                    ensureActive()
                    val packet = cmdReader.readPacket(cmdInput!!)

                    when (packet.type) {
                        PtpConstants.CMD_RESPONSE -> {
                            val respCode = packet.payload?.getUShortLE(0) ?: 0
                            log { "DL_CMD_RESPONSE resp=0x${respCode.toString(16)} downloaded=$totalDownloaded" }
                            if (respCode != PtpConstants.RESPONSE_OK) {
                                return@withContext Result.failure(Exception("传输失败: ${PtpConstants.translateResponse(respCode)}"))
                            }
                            return@withContext Result.success(totalDownloaded to first4?.let { detectExt(it) })
                        }
                        PtpConstants.START_DATA_PACKET -> {
                            expected = packet.payload?.getIntLE(4)?.toLong()?.and(0xFFFFFFFFL) ?: 0L
                            log { "DL_START expected=$expected" }
                        }
                        PtpConstants.DATA_PACKET, PtpConstants.END_DATA_PACKET -> {
                            // DATA 与 END_DATA 同样携带数据段（前 4 字节为 PTP 数据阶段头）。
                            // 先写入本包数据，再判断是否为结束包，避免丢失最后一段数据。
                            val payload = packet.payload
                            if (payload != null && payload.size > 4) {
                                output.write(payload, 4, payload.size - 4)
                                totalDownloaded += payload.size - 4

                                if (first4 == null) {
                                    first4 = payload.copyOfRange(4, minOf(payload.size, 8))
                                }

                                val now = System.currentTimeMillis()
                                if (now - lastProgressTime >= 200) {
                                    val elapsed = (now - startTime) / 1000f
                                    onProgress?.invoke(DownloadProgress(totalDownloaded, expected, elapsed))
                                    lastProgressTime = now
                                }
                            }
                            if (packet.type == PtpConstants.END_DATA_PACKET) {
                                log { "DL_END total=$totalDownloaded, draining CMD_RESPONSE..." }
                                // 必须消费掉本次传输的 CMD_RESPONSE，否则残留包会污染下次传输
                                drainCmdResponse()
                                return@withContext Result.success(totalDownloaded to first4?.let { detectExt(it) })
                            }
                        }
                        PtpConstants.PING -> {
                            log { "DL_PING during download" }
                            sendPong()
                        }
                    }
                }
                @Suppress("UNREACHABLE_CODE")
                Result.failure(Exception("Unexpected end of stream"))
            } catch (e: CancellationException) {
                throw e   // 取消须向上传播，不能包装成失败结果
            } catch (e: Exception) {
                Result.failure(e)
            }
        }
    }

    /**
     * 依据文件头魔数推断扩展名。仅在相机上报的格式码未知（.bin）时作为兜底。
     * 只依赖前若干字节，因此不检测 ISO-BMFF (MOV/MP4) —— 其 'ftyp' 位于偏移 4，
     * 且已知视频格式码已在 [PtpConstants.FORMAT_EXT] 中直接映射。
     */
    private fun detectExt(data: ByteArray): String {
        if (data.size < 2) return ".bin"
        // JPEG: FF D8
        if (data[0] == 0xFF.toByte() && data[1] == 0xD8.toByte()) return ".jpg"
        if (data.size >= 4) {
            // TIFF/NEF 小端: 'I' 'I' 2A 00
            if (data[0] == 'I'.code.toByte() && data[1] == 'I'.code.toByte() &&
                data[2] == 0x2A.toByte() && data[3] == 0x00.toByte()) return ".nef"
            // TIFF/NEF 大端: 'M' 'M' 00 2A
            if (data[0] == 'M'.code.toByte() && data[1] == 'M'.code.toByte() &&
                data[2] == 0x00.toByte() && data[3] == 0x2A.toByte()) return ".nef"
        }
        return ".bin"
    }

    /**
     * 关闭会话与连接。为 suspend 并纳入 [ioMutex] + IO 线程：
     * - 避免在主线程发起 socket 写导致 NetworkOnMainThreadException；
     * - 与进行中的命令/下载互斥，消除并发读写同一 socket 的竞态；
     * - 用 NonCancellable 保证即使调用方作用域已取消也能完成清理。
     */
    suspend fun close() = withContext(NonCancellable + Dispatchers.IO) {
        ioMutex.withLock {
            try {
                sendCmd(PtpConstants.CLOSE_SESSION)
                recvResp()
            } catch (_: Exception) {}
            closeQuietly()
        }
    }

    private fun closeQuietly() {
        try { cmdInput?.close() } catch (_: Exception) {}
        try { cmdSocket?.close() } catch (_: Exception) {}
        try { evtInput?.close() } catch (_: Exception) {}
        try { evtSocket?.close() } catch (_: Exception) {}
        evtThread?.interrupt()
        evtThread = null
    }

    private fun makeInitReq(): ByteArray {
        val hostname = "NikonPTP"
        val nameBytes = hostname.toByteArray(Charsets.UTF_16LE) + byteArrayOf(0, 0)
        val guid = ByteArray(16).also { java.security.SecureRandom().nextBytes(it) }
        val length = 8 + 16 + nameBytes.size + 2
        val pkt = ByteBuffer.allocate(length).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(length)
            putInt(PtpConstants.INIT_CMD_REQ)
            put(guid)
            put(nameBytes)
            putShort(1)
        }.array()
        return pkt
    }

    private fun sendCmd(code: Int, vararg params: Int) {
        val paramCount = params.size.coerceAtMost(5)
        val pkt = ByteBuffer.allocate(18 + paramCount * 4).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(18 + paramCount * 4)
            putInt(PtpConstants.CMD_REQUEST)
            putInt(1)
            putShort(code.toShort())
            putInt(nextTid())
            for (i in 0 until paramCount) {
                putInt(params[i])
            }
        }.array()
        cmdOutput?.write(pkt)
        cmdOutput?.flush()
    }

    private fun sendPong() {
        val pong = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(8)
            putInt(PtpConstants.PONG)
        }.array()
        cmdOutput?.write(pong)
        cmdOutput?.flush()
    }

    private fun recvResp(): Pair<Int, ByteArray?> {
        while (true) {
            val packet = cmdReader.readPacket(cmdInput!!)
            when (packet.type) {
                PtpConstants.CMD_RESPONSE -> {
                    val respCode = packet.payload?.getUShortLE(0) ?: 0
                    return respCode to packet.payload
                }
                PtpConstants.PING -> sendPong()
            }
        }
    }

    private fun recvRespWithPayload(): Pair<Int, ByteArray?> {
        var responseData: ByteArray? = null
        while (true) {
            val packet = cmdReader.readPacket(cmdInput!!)
            when (packet.type) {
                PtpConstants.CMD_RESPONSE -> {
                    val respCode = packet.payload?.getUShortLE(0) ?: 0
                    return respCode to responseData
                }
                PtpConstants.START_DATA_PACKET -> {
                }
                PtpConstants.DATA_PACKET, PtpConstants.END_DATA_PACKET -> {
                    if (packet.payload != null && packet.payload.size > 4) {
                        val data = packet.payload.copyOfRange(4, packet.payload.size)
                        responseData = if (responseData == null) data else responseData + data
                    }
                }
                PtpConstants.PING -> sendPong()
            }
        }
    }

    private fun drainCmdResponse() {
        // 读取并丢弃本次传输的 CMD_RESPONSE
        while (true) {
            val packet = cmdReader.readPacket(cmdInput!!)
            if (packet.type == PtpConstants.CMD_RESPONSE) return
            if (packet.type == PtpConstants.PING) sendPong()
        }
    }

    /** 读取小端无符号 16 位，返回 0..65535，避免高位错误码 (0xAxxx) 被符号扩展。 */
    private fun ByteArray.getUShortLE(offset: Int): Int {
        return (this[offset].toInt() and 0xFF) or ((this[offset + 1].toInt() and 0xFF) shl 8)
    }

    private fun ByteArray.getIntLE(offset: Int): Int {
        return (this[offset].toInt() and 0xFF) or
                ((this[offset + 1].toInt() and 0xFF) shl 8) or
                ((this[offset + 2].toInt() and 0xFF) shl 16) or
                ((this[offset + 3].toInt() and 0xFF) shl 24)
    }
}
