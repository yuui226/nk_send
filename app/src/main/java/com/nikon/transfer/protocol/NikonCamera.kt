package com.nikon.transfer.protocol

import kotlinx.coroutines.Dispatchers
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

        val format = data.getShortLE(4).toInt() and 0xFFFF
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
                    val packet = cmdReader.readPacket(cmdInput!!)

                    when (packet.type) {
                        PtpConstants.CMD_RESPONSE -> {
                            val respCode = packet.payload?.getShortLE(0)?.toInt() ?: 0
                            android.util.Log.d("NikonTransfer", "DL_CMD_RESPONSE resp=0x${respCode.toString(16)} downloaded=$totalDownloaded")
                            if (respCode != PtpConstants.RESPONSE_OK) {
                                return@withContext Result.failure(Exception("传输失败: ${PtpConstants.translateResponse(respCode)}"))
                            }
                            val ext = first4?.let { detectExt(it) }
                            return@withContext Result.success(totalDownloaded to ext)
                        }
                        PtpConstants.START_DATA_PACKET -> {
                            expected = packet.payload?.getIntLE(4)?.toLong() ?: 0L
                            android.util.Log.d("NikonTransfer", "DL_START expected=$expected")
                        }
                        PtpConstants.DATA_PACKET, PtpConstants.END_DATA_PACKET -> {
                            val dataSize = packet.payload?.let { it.size - 4 } ?: 0
                        if (packet.type == PtpConstants.END_DATA_PACKET) {
                            android.util.Log.d("NikonTransfer", "DL_END total=$totalDownloaded, draining CMD_RESPONSE...")
                            // 必须消费掉本次传输的 CMD_RESPONSE，否则残留包会污染下次传输
                            drainCmdResponse()
                            val ext = first4?.let { detectExt(it) }
                            return@withContext Result.success(totalDownloaded to ext)
                        }
                            if (packet.payload != null && packet.payload.size > 4) {
                                val data = packet.payload.copyOfRange(4, packet.payload.size)
                                output.write(data)
                                totalDownloaded += data.size

                                if (first4 == null) {
                                    first4 = if (data.size >= 4) data.copyOf(4) else data.copyOf()
                                }

                                val now = System.currentTimeMillis()
                                if (now - lastProgressTime >= 200) {
                                    val elapsed = (now - startTime) / 1000f
                                    onProgress?.invoke(DownloadProgress(totalDownloaded, expected, elapsed))
                                    lastProgressTime = now
                                }
                            }
                            if (packet.type == PtpConstants.END_DATA_PACKET) {
                                val ext = first4?.let { detectExt(it) }
                                return@withContext Result.success(totalDownloaded to ext)
                            }
                        }
                        PtpConstants.PING -> {
                            android.util.Log.d("NikonTransfer", "DL_PING during download")
                            sendPong()
                        }
                    }
                }
                @Suppress("UNREACHABLE_CODE")
                Result.failure(Exception("Unexpected end of stream"))
            } catch (e: Exception) {
                Result.failure(e)
            }
        }
    }

    private fun detectExt(data: ByteArray): String {
        if (data.size < 2) return ".bin"
        if (data[0] == 0xFF.toByte() && data[1] == 0xD8.toByte()) return ".jpg"
        if (data.size >= 4) {
            val header = String(data, 0, 4, Charsets.US_ASCII)
            if (header == "ftyp") return ".mov"
            if (data[0] == 'I'.code.toByte() && data[1] == 'I'.code.toByte() && data[2] == 0x2A.toByte()) return ".nef"
            if (data[0] == 'M'.code.toByte() && data[1] == 'M'.code.toByte() && data[2] == 0x00.toByte() && data[3] == 0x2A.toByte()) return ".nef"
        }
        return ".bin"
    }

    fun close() {
        try {
            sendCmd(PtpConstants.CLOSE_SESSION)
            recvResp()
        } catch (_: Exception) {}
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
                    val respCode = packet.payload?.getShortLE(0)?.toInt() ?: 0
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
                    val respCode = packet.payload?.getShortLE(0)?.toInt() ?: 0
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

    private fun ByteArray.getShortLE(offset: Int): Short {
        return ((this[offset].toInt() and 0xFF) or ((this[offset + 1].toInt() and 0xFF) shl 8)).toShort()
    }

    private fun ByteArray.getIntLE(offset: Int): Int {
        return (this[offset].toInt() and 0xFF) or
                ((this[offset + 1].toInt() and 0xFF) shl 8) or
                ((this[offset + 2].toInt() and 0xFF) shl 16) or
                ((this[offset + 3].toInt() and 0xFF) shl 24)
    }
}
