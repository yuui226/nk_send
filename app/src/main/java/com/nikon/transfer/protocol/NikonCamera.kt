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

/** 写入本地文件失败（非相机连接错误），用于区分"掉线"与"磁盘/存储"问题。 */
class OutputWriteException(cause: Throwable) : Exception("写入文件失败: ${cause.message}", cause)

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
    // 会话是否已 OpenSession 成功；用于决定 close() 是否需要发送 CloseSession，
    // 避免在握手中途失败时空等 CloseSession 响应（最长可达 soTimeout）。
    @Volatile private var sessionOpen = false

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
                // 不手动设置 receiveBufferSize：本地 Wi-Fi 带宽延迟积极小，自动调优的窗口已足够
                // (家里实测自动调优即可跑满 ~2MB/s)。手动设 SO_RCVBUF 会关闭内核接收窗口自动调优，
                // 是没必要的干预，故交给系统。
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
            sessionOpen = true

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
        /** 归一化扩展名：小写且带前导点（如 ".jpg"）；无扩展名返回 ""。UI 按此比较颜色/图标。 */
        val extension: String
            get() {
                val i = fileName.lastIndexOf('.')
                return if (i < 0) "" else fileName.substring(i).lowercase()
            }
    }

    /** 通过 PTP GetThumb 获取缩略图 JPEG 字节；无缩略图或出错返回 null。与其它命令共用 ioMutex。 */
    suspend fun getThumbnail(handle: Int): ByteArray? = ioMutex.withLock {
        withContext(Dispatchers.IO) {
            try {
                sendCmd(PtpConstants.GET_THUMB, handle)
                val (respCode, data) = recvRespWithPayload()
                if (respCode == PtpConstants.RESPONSE_OK) data else null
            } catch (_: Exception) {
                null
            }
        }
    }

    suspend fun streamFileInfo(
        handles: List<Int>,
        batchSize: Int = 20,
        onBatch: suspend (List<FileInfo>, Int, Int) -> Unit
    ) = withContext(Dispatchers.IO) {
        val total = handles.size
        var loaded = 0
        handles.chunked(batchSize).forEach { batch ->
            // 每批单独持锁，批间释放 ioMutex：缩略图模式下缩略图请求可在批间插入，
            // 从而随列表一起渐进出图，而不是等整份列表加载完才开始。
            val files = ioMutex.withLock {
                batch.mapNotNull { handle ->
                    try { getObjectInfoInternal(handle) } catch (_: Exception) { null }
                }
            }
            loaded += files.size
            if (files.isNotEmpty()) {
                onBatch(files, loaded, total)
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
    ): Result<Long> = ioMutex.withLock {
        withContext(Dispatchers.IO) {
            try {
                sendCmd(PtpConstants.GET_OBJECT, handle)

                var totalDownloaded = 0L
                var expected = 0L
                val startTime = System.currentTimeMillis()
                var lastProgressTime = startTime

                while (true) {
                    // 协作式取消：在每个包边界检查，使 cancelTransfer() 能及时中断
                    ensureActive()
                    // 零拷贝读取：直接从共享缓冲区写入，避免每包一次全量分配+复制。
                    val packet = cmdReader.readPacketRaw(cmdInput!!)
                    val buf = packet.buffer
                    val len = packet.payloadLen

                    when (packet.type) {
                        PtpConstants.CMD_RESPONSE -> {
                            val respCode = if (len >= 2) buf.getUShortLE(0) else 0
                            log { "DL_CMD_RESPONSE resp=0x${respCode.toString(16)} downloaded=$totalDownloaded" }
                            if (respCode != PtpConstants.RESPONSE_OK) {
                                return@withContext Result.failure(Exception("传输失败: ${PtpConstants.translateResponse(respCode)}"))
                            }
                            return@withContext Result.success(totalDownloaded)
                        }
                        PtpConstants.START_DATA_PACKET -> {
                            expected = if (len >= 8) buf.getIntLE(4).toLong() and 0xFFFFFFFFL else 0L
                            log { "DL_START expected=$expected" }
                        }
                        PtpConstants.DATA_PACKET, PtpConstants.END_DATA_PACKET -> {
                            // DATA 与 END_DATA 同样携带数据段（前 4 字节为 PTP 数据阶段头）。
                            // 先写入本包数据，再判断是否为结束包，避免丢失最后一段数据。
                            if (len > 4) {
                                try {
                                    output.write(buf, 4, len - 4)
                                } catch (e: java.io.IOException) {
                                    // 写本地文件失败（如存储空间不足）——非相机连接问题，
                                    // 包装成非 IOException 以便上层按单文件失败处理，而不是误判为掉线。
                                    return@withContext Result.failure(OutputWriteException(e))
                                }
                                totalDownloaded += len - 4

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
                                return@withContext Result.success(totalDownloaded)
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
     * 关闭会话与连接。为 suspend 并纳入 [ioMutex] + IO 线程：
     * - 避免在主线程发起 socket 写导致 NetworkOnMainThreadException；
     * - 与进行中的命令/下载互斥，消除并发读写同一 socket 的竞态；
     * - 用 NonCancellable 保证即使调用方作用域已取消也能完成清理。
     */
    suspend fun close() = withContext(NonCancellable + Dispatchers.IO) {
        ioMutex.withLock {
            // 仅在会话确实打开时才发送 CloseSession，否则握手中途失败时会空等响应。
            if (sessionOpen) {
                try {
                    sendCmd(PtpConstants.CLOSE_SESSION)
                    recvResp()
                } catch (_: Exception) {}
            }
            closeQuietly()
        }
    }

    /**
     * 强制关闭底层 socket 以立即中断正在阻塞的读操作（不经过 ioMutex，因为持锁方正卡在读上）。
     * 用于 Wi-Fi 掉线时快速中止进行中的下载；之后仍应调用 [close] 做完整清理（幂等）。
     */
    fun forceClose() {
        sessionOpen = false
        try { cmdSocket?.close() } catch (_: Exception) {}
        try { evtSocket?.close() } catch (_: Exception) {}
    }

    private fun closeQuietly() {
        sessionOpen = false
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
        // 用 ByteArrayOutputStream 累积多包数据，避免 responseData + data 的 O(n²) 复制。
        var buffer: java.io.ByteArrayOutputStream? = null
        while (true) {
            val packet = cmdReader.readPacket(cmdInput!!)
            when (packet.type) {
                PtpConstants.CMD_RESPONSE -> {
                    val respCode = packet.payload?.getUShortLE(0) ?: 0
                    return respCode to buffer?.toByteArray()
                }
                PtpConstants.DATA_PACKET, PtpConstants.END_DATA_PACKET -> {
                    val p = packet.payload
                    if (p != null && p.size > 4) {
                        val out = buffer ?: java.io.ByteArrayOutputStream().also { buffer = it }
                        out.write(p, 4, p.size - 4)
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
