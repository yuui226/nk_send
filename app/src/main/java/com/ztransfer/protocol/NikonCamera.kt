package com.ztransfer.protocol

import android.content.Context
import android.net.Network
import com.ztransfer.BuildConfig
import com.ztransfer.R
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
class OutputWriteException(message: String, cause: Throwable) : Exception(message, cause)

class NikonCamera(private val context: Context) {
    private var cmdSocket: Socket? = null
    private var evtSocket: Socket? = null
    private var cmdInput: java.io.InputStream? = null
    private var evtInput: java.io.InputStream? = null
    private var cmdOutput: OutputStream? = null
    private var tid = 0
    private val cmdReader = PacketReader(context)
    private val evtReader = PacketReader(context)
    private var evtThread: Thread? = null
    // internal 而非 private:遥控实验(RemoteLab.kt)以扩展函数复用同一互斥与收发原语,
    // 保证实验命令与传输/缩略图/心跳严格串行,不引入第二条 IO 路径。
    internal val ioMutex = Mutex()
    // 会话是否已 OpenSession 成功；用于决定 close() 是否需要发送 CloseSession，
    // 避免在握手中途失败时空等 CloseSession 响应（最长可达 soTimeout）。
    @Volatile private var sessionOpen = false
    // Nikon GetPartialObjectEx (0x9431) 支持探测：null=未探测, true=支持, false=不支持。
    // 仅首块失败时置为 false 并回退到全量下载；同一会话后续大文件不再试探。
    // 标准 PTP 0x101B 在 Nikon 机身上不被识别，须用此专有操作码。
    @Volatile private var partialObjectSupported: Boolean? = null

    companion object {
        const val TAG = "ZTransfer"
        // 命令/事件通道的常规读超时。
        const val SO_TIMEOUT_MS = 60_000
        // TCP 连接超时：本地热点正常握手 <300ms；缩短它让"相机侧 PTP 服务还没就绪"的
        // 失败尝试更快结束、更快进入下一轮重试。
        const val CONNECT_TIMEOUT_MS = 3_000
        // 取消下载的排空安全阀：已向相机发送 Cancel 包后，在途数据只剩 ≈TCP 窗口的数 MB，
        // 排空应秒级完成；若累计排空超过该预算仍没等到响应包，说明机型不支持 Cancel、
        // 还在发整个文件——此时才断开由心跳/看护自动重连（断开会让相机侧会话挂起甚至
        // 关 Wi-Fi，重连可达数十秒，"停止后重试卡很久"，所以只作为兜底而非首选）。
        const val CANCEL_DRAIN_BUDGET = 32L * 1024 * 1024
        // 排空期间的读超时：部分机型收到 Cancel 停发数据后并不回 CMD_RESPONSE，按常规
        // 60s 超时会抱着 ioMutex 白等一分钟——重试的首个下载全程被挡住，表现为
        // "停止后重试卡半天没速度"。静默 3s 即认定连接不可用，断开走自动重连。
        const val CANCEL_DRAIN_TIMEOUT_MS = 3_000
        // 大于此阈值的文件走分块下载 (GetPartialObject)，防止相机 PTP 事务超时断连。
        // Nikon 相机单次 PTP 事务通常有 2-3 分钟超时，大视频全量下载容易触发。
        const val CHUNK_DOWNLOAD_THRESHOLD = 128L * 1024 * 1024  // 128 MB
        // 每块大小：足够大以最小化块间命令开销，足够小以远低于相机超时 (64MB @2MB/s ≈32s)。
        // 也是断点续传的检查点粒度——传输中断后最多重传当前块。
        // internal: TransferViewModel 引用此值做续传偏移对齐。
        const val CHUNK_SIZE = 64L * 1024 * 1024                 // 64 MB
    }

    /** 仅 debug 构建输出协议日志，避免 release 包泄露 handle/size 并拖慢热路径。 */
    private inline fun log(message: () -> String) {
        if (BuildConfig.DEBUG) android.util.Log.d(TAG, message())
    }

    private fun nextTid(): Int {
        tid++
        return tid
    }

    suspend fun connect(
        ip: String = PtpConstants.CAMERA_IP,
        network: Network? = null
    ): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            // 经 Wi-Fi Network 的 socketFactory 建 socket：相机热点没有互联网，系统验证失败后
            // 常把【默认网络】切回蜂窝数据——普通 Socket() 走默认路由，连 192.168.1.1 的包进蜂窝
            // 黑洞，每次尝试烧满连接超时，直到系统把默认网切回 Wi-Fi 才能成功（用户感知
            // "连上 Wi-Fi 后还要干等一阵"）。绑定到 Wi-Fi 网络后首次尝试即可达。
            fun newSocket(): Socket = network?.socketFactory?.createSocket() ?: Socket()
            cmdSocket = newSocket().apply {
                tcpNoDelay = true
                soTimeout = SO_TIMEOUT_MS
                // 显式加大接收缓冲，撑起 TCP 接收窗口（4MB 远大于本地 Wi-Fi 所需，不会成为瓶颈；
                // 在延迟稍高时也能避免小窗口拖慢吞吐）。必须在 connect 前设置才对窗口缩放生效。
                receiveBufferSize = 4 * 1024 * 1024
                connect(InetSocketAddress(ip, PtpConstants.PTP_PORT), CONNECT_TIMEOUT_MS)
            }
            // 用 BufferedInputStream 批量化 socket 读：每包 8 字节头 + 小数据段本会产生大量 read 系统调用，
            // 缓冲后合并为大块读，减少系统调用开销（大数据段仍会直读进目标缓冲，无额外拷贝）。
            cmdInput = java.io.BufferedInputStream(cmdSocket!!.getInputStream(), 64 * 1024)
            cmdOutput = cmdSocket!!.getOutputStream()

            cmdOutput!!.write(makeInitReq())
            cmdOutput!!.flush()

            val ack = cmdReader.readPacket(cmdInput!!)
            if (ack.type != PtpConstants.INIT_CMD_ACK) {
                // INIT_FAIL = 相机主动拒绝（如未配对/连接数已满），与协议错乱区分开提示。
                return@withContext Result.failure(
                    if (ack.type == PtpConstants.INIT_FAIL) Exception(context.getString(R.string.error_camera_refused))
                    else Exception(context.getString(R.string.error_handshake_bad_ack))
                )
            }

            val payload = ack.payload ?: return@withContext Result.failure(Exception(context.getString(R.string.error_handshake_empty)))
            val sessionId = payload.getIntLE(0)

            evtSocket = newSocket().apply {
                soTimeout = SO_TIMEOUT_MS
                connect(InetSocketAddress(ip, PtpConstants.PTP_PORT), CONNECT_TIMEOUT_MS)
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
                return@withContext Result.failure(Exception(context.getString(R.string.error_event_handshake)))
            }

            sendCmd(PtpConstants.OPEN_SESSION, sessionId)
            val resp = recvResp()
            // 0x201E Session Already Open：App 异常退出后相机侧旧会话可能未清，
            // 视为会话已就绪继续使用，否则会陷入"反复重连直到相机自己超时"的循环。
            if (resp != PtpConstants.RESPONSE_OK && resp != PtpConstants.SESSION_ALREADY_OPEN) {
                return@withContext Result.failure(Exception(context.getString(R.string.error_open_session, PtpConstants.translateResponse(context, resp))))
            }
            sessionOpen = true

            startEvtThread()

            Result.success(Unit)
        } catch (e: Exception) {
            close()
            Result.failure(e)
        }
    }

    private fun startEvtThread() {
        val socket = evtSocket ?: return
        val input = evtInput ?: return
        evtThread = Thread {
            try {
                // 事件通道长时间无事件是常态：握手后取消读超时，阻塞等待即可。
                //（之前沿用 60s 超时会让本线程在空闲后静默退出，之后事件通道无人读、
                // PING 无人应答，长时间挂机可能被相机判定失联。）
                socket.soTimeout = 0
                val output = socket.getOutputStream()
                while (true) {
                    val packet = evtReader.readPacket(input)
                    // 部分机型在事件通道发 PING 保活，必须在本通道应答。
                    if (packet.type == PtpConstants.PING) {
                        sendPong(output)
                    }
                }
            } catch (_: Exception) {
                // socket 关闭/连接断开：线程自然结束。掉线由命令通道的心跳发现并触发重连。
            }
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
                // 能收到【任何】响应就证明链路活着；非 OK（如相机忙碌时的 DeviceBusy）
                // 不代表断线——按响应码判死会把健康连接误杀掉重连，相机侧反而可能
                // 因此挂会话/关热点。只有 IO 异常（socket 死）才算失联。
                recvResp()
                true
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
        val size: Long,
        val fileName: String,
        /** PTP DateTime 完整串（YYYYMMDDThhmmss…，至少 8 位日期）；分组取前 8 位，组内按完整串排序。 */
        val captureDate: String?
    ) {
        /** 归一化扩展名：小写且带前导点（如 ".jpg"）；无扩展名返回 ""。UI 按此比较颜色/图标。 */
        val extension: String
            get() {
                val i = fileName.lastIndexOf('.')
                return if (i < 0) "" else fileName.substring(i).lowercase()
            }
    }

    /**
     * 通过 PTP GetThumb 获取缩略图 JPEG 字节。相机【确认】无缩略图（No_Thumbnail_Present /
     * Invalid_Object_Handle）返回 null——调用方可安全负缓存、不再重试；
     * 其它非 OK 响应（如设备忙）与 IO 失败一律抛出——那是瞬时状态，负缓存会把
     * 恰好赶上相机忙碌时段的整批缩略图永久打成"无图"。与其它命令共用 ioMutex。
     */
    suspend fun getThumbnail(handle: Int): ByteArray? = ioMutex.withLock {
        withContext(Dispatchers.IO) {
            sendCmd(PtpConstants.GET_THUMB, handle)
            val (respCode, data) = recvRespWithPayload()
            when (respCode) {
                PtpConstants.RESPONSE_OK -> data
                PtpConstants.NO_THUMBNAIL_PRESENT,
                PtpConstants.INVALID_OBJECT_HANDLE -> null
                else -> throw Exception("GetThumb: ${PtpConstants.translateResponse(context, respCode)}")
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
            // IO 异常（掉线/读超时）直接向上抛给调用方终止扫描：逐个 handle 硬试会让
            // 每个都等满 60s 读超时、扫描假死数十分钟；单文件 PTP 级失败在
            // getObjectInfoInternal 内已按 null 跳过，不会走到这里。
            val files = ioMutex.withLock {
                batch.mapNotNull { handle -> getObjectInfoInternal(handle) }
            }
            loaded += files.size
            if (files.isNotEmpty()) {
                onBatch(files, loaded, total)
            }
        }
    }

    internal fun getObjectInfoInternal(handle: Int): FileInfo? {
        sendCmd(PtpConstants.GET_OBJECT_INFO, handle)
        val (respCode, data) = recvRespWithPayload()
        if (respCode != PtpConstants.RESPONSE_OK || data == null || data.size < 53) {
            return null
        }

        val format = data.getUShortLE(4)
        // PTP ObjectInfo 的大小字段是 32 位无符号；>4GB 的对象（长视频）相机报 0xFFFFFFFF（未知）。
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
                    // 保留完整的 PTP DateTime（YYYYMMDDThhmmss…），前 8 位为日期。
                    // UI 按前 8 位分组、按完整串在组内排时间序——只存日期的话组内排序就是无效操作。
                    dateStr.takeIf { it.length >= 8 }
                } else null
            } catch (_: Exception) { null }
        } else null

        return FileInfo(handle, size, fileName, captureDate)
    }

    data class DownloadProgress(
        val downloaded: Long,
        val total: Long,
        val elapsed: Float
    )

    /**
     * 查询文件真实 64 位大小（字节）。当 ObjectInfo 对 >4GB 文件报 SIZE_UNKNOWN (0xFFFFFFFF)
     * 时调用此方法获取精确值，以便分块下载和完整性校验。
     * 返回 null 表示操作码不支持或 IO 失败——调用方应回退到 SIZE_UNKNOWN 路径。
     *
     * 通过 [ioMutex] 与其它命令串行。downloadToFile 内部调用时走 [getObjectSizeInternal]
     * 避免重复获取同一 Mutex（kotlinx Mutex 不可重入）。
     */
    suspend fun getObjectSize(handle: Int): Long? = ioMutex.withLock {
        withContext(Dispatchers.IO) { getObjectSizeInternal(handle) }
    }

    /** 不持锁的 [getObjectSize] 实现，仅供已持有 [ioMutex] 的上下文（如 downloadToFile）调用。 */
    private fun getObjectSizeInternal(handle: Int): Long? {
        try {
            sendCmd(PtpConstants.NK_GET_OBJECT_SIZE, handle)
            val (respCode, data) = recvRespWithPayload()
            if (respCode != PtpConstants.RESPONSE_OK || data == null || data.size < 8) {
                log { "GetObjectSize failed: resp=0x${respCode.toString(16)}" }
                return null
            }
            val size = data.getLongLE(0)
            log { "GetObjectSize handle=$handle size=$size" }
            return if (size > 0) size else null
        } catch (_: Exception) {
            return null
        }
    }

    /** 单文件下载完成后的下载速度（MB/s，1024 进制，与 UI formatSpeed 同口径；纯网络读取吞吐）。 */
    data class DownloadStats(
        val bytes: Long,
        val mbps: Float
    )

    /**
     * 下载文件到 [output]。[totalSize] 为 ObjectInfo 中的文件大小（0 或 SIZE_UNKNOWN 表示未知，
     * 走全量下载）；[resumeOffset] 非零时分块下载从该偏移开始（断点续传入口），
     * 调用方负责确保 output 已定位到该偏移。
     */
    suspend fun downloadToFile(
        handle: Int,
        output: OutputStream,
        onProgress: ((DownloadProgress) -> Unit)? = null,
        resumeOffset: Long = 0L,
        totalSize: Long = 0L
    ): Result<DownloadStats> = ioMutex.withLock {
        withContext(Dispatchers.IO) {
            var totalDownloaded = resumeOffset
            var expected = 0L
            val startTime = System.currentTimeMillis()
            var lastProgressTime = startTime
            var readNanos = 0L

            fun buildStats(): DownloadStats {
                val mbps = if (readNanos > 0) totalDownloaded / (readNanos / 1e9f) / (1024f * 1024f) else 0f
                return DownloadStats(totalDownloaded, mbps)
            }
            fun verifyComplete(): Result<DownloadStats>? =
                if (expected > 0 && expected != PtpConstants.SIZE_UNKNOWN && expected != -1L && totalDownloaded != expected) {
                    Result.failure(Exception(context.getString(R.string.error_incomplete_data, totalDownloaded, expected)))
                } else null

            // 对 >4GB 文件（ObjectInfo 报 SIZE_UNKNOWN）用 GetObjectSize 获取真实 64 位大小。
            // 用 internal 版本：当前已在 ioMutex 内，不可重入。
            var effectiveSize = totalSize
            if (totalSize == PtpConstants.SIZE_UNKNOWN || totalSize <= 0L) {
                val realSize = getObjectSizeInternal(handle)
                if (realSize != null && realSize > 0) {
                    effectiveSize = realSize
                    log { "DL_SIZE resolved: $totalSize -> $realSize via GetObjectSize" }
                }
            }

            // 决定是否走分块下载
            val useChunked = effectiveSize > CHUNK_DOWNLOAD_THRESHOLD && effectiveSize != PtpConstants.SIZE_UNKNOWN
                && partialObjectSupported != false

            if (useChunked) {
                // ===== 分块下载路径 =====
                var offset = resumeOffset
                var firstChunk = true
                var fallbackToFull = false
                try {
                    while (offset < effectiveSize && !fallbackToFull) {
                        ensureActive()
                        val chunkSize = minOf(CHUNK_SIZE, effectiveSize - offset).toInt()
                        val offsetLow = (offset and 0xFFFFFFFFL).toInt()
                        val offsetHigh = (offset shr 32).toInt()

                        log { "DL_CHUNK offset=$offset size=$chunkSize" }
                        // Nikon 专有 GetPartialObjectEx: 5 参数 (handle, offLo, offHi, sizeLo, sizeHi)
                        sendCmd(PtpConstants.NK_GET_PARTIAL_OBJECT_EX, handle, offsetLow, offsetHigh, chunkSize, 0)

                        var chunkExpected = 0L
                        var chunkDownloaded = 0L
                        var chunkDone = false

                        while (!chunkDone) {
                            ensureActive()
                            val rt0 = System.nanoTime()
                            val packet = cmdReader.readPacketRaw(cmdInput!!)
                            readNanos += System.nanoTime() - rt0
                            val buf = packet.buffer
                            val len = packet.payloadLen

                            when (packet.type) {
                                PtpConstants.CMD_RESPONSE -> {
                                    val respCode = if (len >= 2) buf.getUShortLE(0) else 0
                                    log { "DL_CHUNK_RESP resp=0x${respCode.toString(16)} offset=$offset" }
                                    if (firstChunk && respCode != PtpConstants.RESPONSE_OK) {
                                        // 首块非 OK → 操作码不支持或参数非法，标记回退出分块循环
                                        partialObjectSupported = false
                                        fallbackToFull = true
                                        log { "DL_PARTIAL not supported (resp=0x${respCode.toString(16)}), falling back to full" }
                                        chunkDone = true
                                    } else if (respCode != PtpConstants.RESPONSE_OK) {
                                        return@withContext Result.failure(Exception(
                                            context.getString(R.string.error_transfer_failed_reason, PtpConstants.translateResponse(context, respCode))
                                        ))
                                    } else {
                                        // OK：校验本块完整性（可能比 END_DATA_PACKET 先到，统一在此校验）
                                        if (chunkExpected > 0 && chunkDownloaded != chunkExpected) {
                                            return@withContext Result.failure(Exception(
                                                context.getString(R.string.error_incomplete_data, chunkDownloaded, chunkExpected)
                                            ))
                                        }
                                        chunkDone = true
                                    }
                                }
                                PtpConstants.START_DATA_PACKET -> {
                                    chunkExpected = when {
                                        len >= 12 -> buf.getLongLE(4)
                                        len >= 8 -> buf.getIntLE(4).toLong() and 0xFFFFFFFFL
                                        else -> 0L
                                    }
                                    log { "DL_CHUNK_START expected=$chunkExpected" }
                                }
                                PtpConstants.DATA_PACKET, PtpConstants.END_DATA_PACKET -> {
                                    if (len > 4) {
                                        try {
                                            output.write(buf, 4, len - 4)
                                        } catch (e: java.io.IOException) {
                                            return@withContext Result.failure(
                                                OutputWriteException(context.getString(R.string.error_write_file, e.message), e)
                                            )
                                        }
                                        totalDownloaded += len - 4
                                        chunkDownloaded += len - 4

                                        val now = System.currentTimeMillis()
                                        if (now - lastProgressTime >= 200) {
                                            val elapsed = (now - startTime) / 1000f
                                            onProgress?.invoke(DownloadProgress(totalDownloaded, effectiveSize, elapsed))
                                            lastProgressTime = now
                                        }
                                    }
                                    if (packet.type == PtpConstants.END_DATA_PACKET) {
                                        drainCmdResponse()
                                        if (chunkExpected > 0 && chunkDownloaded != chunkExpected) {
                                            return@withContext Result.failure(Exception(
                                                context.getString(R.string.error_incomplete_data, chunkDownloaded, chunkExpected)
                                            ))
                                        }
                                        chunkDone = true
                                    }
                                }
                                PtpConstants.PING -> {
                                    sendPong(cmdOutput)
                                }
                            }
                        }

                        offset += chunkSize
                        firstChunk = false
                    }

                    // 全部分块完成（非回退场景才返回；回退场景走全量下载）
                    if (!fallbackToFull) {
                        return@withContext Result.success(buildStats())
                    }
                    // fallbackToFull: 重置累加器，继续走全量下载
                    totalDownloaded = 0L
                    expected = 0L
                    readNanos = 0L
                    lastProgressTime = System.currentTimeMillis()
                } catch (e: CancellationException) {
                    try {
                        withContext(NonCancellable) {
                            sendCancel()
                            cmdSocket?.soTimeout = CANCEL_DRAIN_TIMEOUT_MS
                            if (drainCmdResponse(CANCEL_DRAIN_BUDGET)) {
                                cmdSocket?.soTimeout = SO_TIMEOUT_MS
                            } else {
                                log { "DL_CHUNK_CANCEL drain budget exceeded, closing" }
                                closeQuietly()
                            }
                        }
                    } catch (_: Exception) {
                        closeQuietly()
                    }
                    throw e
                } catch (e: Exception) {
                    return@withContext Result.failure(e)
                }
            }

            // ===== 全量下载路径（含分块不支持回退） =====
            totalDownloaded = 0L
            expected = 0L
            val savedTimeout = cmdSocket?.soTimeout
            cmdSocket?.soTimeout = 0
            try {
                try {
                    sendCmd(PtpConstants.GET_OBJECT, handle)

                    while (true) {
                        ensureActive()
                        val rt0 = System.nanoTime()
                        val packet = cmdReader.readPacketRaw(cmdInput!!)
                        readNanos += System.nanoTime() - rt0
                        val buf = packet.buffer
                        val len = packet.payloadLen

                        when (packet.type) {
                            PtpConstants.CMD_RESPONSE -> {
                                val respCode = if (len >= 2) buf.getUShortLE(0) else 0
                                log { "DL_CMD_RESPONSE resp=0x${respCode.toString(16)} downloaded=$totalDownloaded" }
                                if (respCode != PtpConstants.RESPONSE_OK) {
                                    return@withContext Result.failure(Exception(
                                        context.getString(R.string.error_transfer_failed_reason, PtpConstants.translateResponse(context, respCode))
                                    ))
                                }
                                return@withContext (verifyComplete() ?: Result.success(buildStats()))
                            }
                            PtpConstants.START_DATA_PACKET -> {
                                expected = when {
                                    len >= 12 -> buf.getLongLE(4)
                                    len >= 8 -> buf.getIntLE(4).toLong() and 0xFFFFFFFFL
                                    else -> 0L
                                }
                                log { "DL_START expected=$expected" }
                            }
                            PtpConstants.DATA_PACKET, PtpConstants.END_DATA_PACKET -> {
                                if (len > 4) {
                                    try {
                                        output.write(buf, 4, len - 4)
                                    } catch (e: java.io.IOException) {
                                        return@withContext Result.failure(
                                            OutputWriteException(context.getString(R.string.error_write_file, e.message), e)
                                        )
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
                                    drainCmdResponse()
                                    return@withContext (verifyComplete() ?: Result.success(buildStats()))
                                }
                            }
                            PtpConstants.PING -> {
                                log { "DL_PING during download" }
                                sendPong(cmdOutput)
                            }
                        }
                    }
                    @Suppress("UNREACHABLE_CODE")
                    Result.failure(Exception("Unexpected end of stream"))
                } catch (e: CancellationException) {
                    try {
                        withContext(NonCancellable) {
                            sendCancel()
                            cmdSocket?.soTimeout = CANCEL_DRAIN_TIMEOUT_MS
                            if (drainCmdResponse(CANCEL_DRAIN_BUDGET)) {
                                cmdSocket?.soTimeout = SO_TIMEOUT_MS
                            } else {
                                log { "DL_CANCEL drain budget exceeded, closing" }
                                closeQuietly()
                            }
                        }
                    } catch (_: Exception) {
                        closeQuietly()
                    }
                    throw e
                } catch (e: Exception) {
                    Result.failure(e)
                }
            } finally {
                cmdSocket?.soTimeout = savedTimeout ?: SO_TIMEOUT_MS
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

    internal fun sendCmd(code: Int, vararg params: Int) {
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

    /**
     * 带 data-out 数据阶段的命令（如 SetDevicePropValue）：CMD_REQUEST(dataPhase=2)
     * + Start-Data + End-Data（小载荷一包发完）。仅遥控实验（RemoteLab.kt）使用，
     * 正式传输路径没有 data-out 场景。
     */
    internal fun sendCmdWithData(code: Int, data: ByteArray, vararg params: Int) {
        val paramCount = params.size.coerceAtMost(5)
        val t = nextTid()
        val pkt = ByteBuffer.allocate(18 + paramCount * 4 + 20 + 12 + data.size)
            .order(ByteOrder.LITTLE_ENDIAN).apply {
                // CMD_REQUEST，dataPhaseInfo=2（本事务带 data-out 阶段）
                putInt(18 + paramCount * 4)
                putInt(PtpConstants.CMD_REQUEST)
                putInt(2)
                putShort(code.toShort())
                putInt(t)
                for (i in 0 until paramCount) putInt(params[i])
                // Start-Data：TID + 总长（64 位）
                putInt(20)
                putInt(PtpConstants.START_DATA_PACKET)
                putInt(t)
                putLong(data.size.toLong())
                // End-Data：TID + 数据
                putInt(12 + data.size)
                putInt(PtpConstants.END_DATA_PACKET)
                putInt(t)
                put(data)
            }.array()
        cmdOutput?.write(pkt)
        cmdOutput?.flush()
    }

    /** 应答 PING。命令通道传 [cmdOutput]，事件通道传其自身输出流（各自独立，无并发冲突）。 */
    private fun sendPong(output: OutputStream?) {
        val pong = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(8)
            putInt(PtpConstants.PONG)
        }.array()
        output?.write(pong)
        output?.flush()
    }

    /** 等待并返回响应码。中途丢弃的数据包（如 keepalive 的 GetStorageIds 数据段）用 raw 读，不逐包分配。 */
    private fun recvResp(): Int {
        while (true) {
            val packet = cmdReader.readPacketRaw(cmdInput!!)
            when (packet.type) {
                PtpConstants.CMD_RESPONSE ->
                    return if (packet.payloadLen >= 2) packet.buffer.getUShortLE(0) else 0
                PtpConstants.PING -> sendPong(cmdOutput)
            }
        }
    }

    internal fun recvRespWithPayload(): Pair<Int, ByteArray?> {
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
                PtpConstants.PING -> sendPong(cmdOutput)
            }
        }
    }

    private fun drainCmdResponse() {
        // 读取并丢弃直到本次传输的 CMD_RESPONSE。成功路径此时只剩 CMD_RESPONSE；
        // 用 raw 读避免逐包分配。
        while (true) {
            val packet = cmdReader.readPacketRaw(cmdInput!!)
            if (packet.type == PtpConstants.CMD_RESPONSE) return
            if (packet.type == PtpConstants.PING) sendPong(cmdOutput)
        }
    }

    /**
     * 带预算的排空（取消路径专用）：读取并丢弃直到 CMD_RESPONSE，返回 true；
     * 累计排空超过 [maxBytes] 仍没等到响应（机型不理会 Cancel、还在发整个文件）返回 false。
     */
    private fun drainCmdResponse(maxBytes: Long): Boolean {
        var drained = 0L
        while (drained <= maxBytes) {
            val packet = cmdReader.readPacketRaw(cmdInput!!)
            when (packet.type) {
                PtpConstants.CMD_RESPONSE -> return true
                PtpConstants.PING -> sendPong(cmdOutput)
                else -> drained += packet.payloadLen
            }
        }
        return false
    }

    /** PTP/IP Cancel 包：请求相机中止当前事务（[tid] 为最后发出的事务号）的数据阶段。 */
    private fun sendCancel() {
        val pkt = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(12)
            putInt(PtpConstants.CANCEL)
            putInt(tid)
        }.array()
        cmdOutput?.write(pkt)
        cmdOutput?.flush()
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

    private fun ByteArray.getLongLE(offset: Int): Long {
        return (getIntLE(offset).toLong() and 0xFFFFFFFFL) or (getIntLE(offset + 4).toLong() shl 32)
    }
}
