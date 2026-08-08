package com.ztransfer.protocol

import android.content.Context
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.net.Network
import android.os.SystemClock
import com.ztransfer.BuildConfig
import com.ztransfer.R
import com.ztransfer.diagnostics.FileOrderProbe
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
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

/** PTP/IP 已响应但相机明确拒绝初始化；区别于普通网络不可达。 */
class CameraRefusedException(message: String) : Exception(message)

/**
 * 多卡流式归并时选择下一条。每张卡自己的 head 已经是该卡当前最新文件；跨卡只比较
 * ObjectInfo 拍摄时间。日期缺失的 head 优先弹出，避免它挡住同卡后续所有正常文件。
 * 时间相同保持卡槽输入顺序稳定，不再拿不透明的 handle 数值打破平局。
 */
internal fun selectNewestFileHeadIndex(
    heads: List<NikonCamera.FileInfo?>,
): Int? {
    var selected = -1
    heads.forEachIndexed { index, candidate ->
        if (candidate == null) return@forEachIndexed
        if (selected < 0) {
            selected = index
            return@forEachIndexed
        }
        val selectedFile = heads[selected] ?: return@forEachIndexed
        val candidateDate = candidate.captureDate
        val selectedDate = selectedFile.captureDate
        val candidateIsNewer = when {
            candidateDate == null && selectedDate != null -> true
            candidateDate != null && selectedDate == null -> false
            candidateDate == null -> false
            else -> candidateDate > checkNotNull(selectedDate)
        }
        if (candidateIsNewer) selected = index
    }
    return selected.takeIf { it >= 0 }
}

/**
 * 续传无法进行：已有半成品，但本次下载走不了分块路径（相机不支持 GetPartialObjectEx，
 * 或 >4GB 文件拿不到真实大小无法对齐）。全量 GetObject 只能从 0 开始、会写坏已定位到
 * 续传偏移的输出流，故绝不静默降级——抛此异常让调用方删掉半成品、从头重下。
 */
class ResumeUnavailableException : Exception()

/**
 * FHD 能力判断只区分协议明确不支持与可恢复失败。相机忙、handle 失效、空数据以及厂商
 * 临时错误都不能被升级成整场会话不支持，否则后台预取的一次失败会毒化后续大图预览。
 */
internal enum class FhdResponseDisposition {
    SUCCESS,
    TRANSIENT_FAILURE,
    UNSUPPORTED,
}

internal fun classifyFhdResponse(
    responseCode: Int,
    hasPayload: Boolean,
): FhdResponseDisposition = when {
    responseCode == PtpConstants.RESPONSE_OK && hasPayload -> FhdResponseDisposition.SUCCESS
    responseCode == PtpConstants.OPERATION_NOT_SUPPORTED -> FhdResponseDisposition.UNSUPPORTED
    else -> FhdResponseDisposition.TRANSIENT_FAILURE
}

internal fun updateFhdSupport(
    current: Boolean?,
    disposition: FhdResponseDisposition,
): Boolean? = when (disposition) {
    FhdResponseDisposition.SUCCESS -> true
    FhdResponseDisposition.UNSUPPORTED -> if (current == true) true else false
    FhdResponseDisposition.TRANSIENT_FAILURE -> current
}

/**
 * 单命令通道的轻量调度器。普通命令仍直接使用 [mutex]；交互式大图/EXIF 在排队前
 * 登记，分块传输在每个完整 PTP 事务之间检查登记，让交互请求先取得下一段通道。
 */
internal class CameraIoGate(
    val mutex: Mutex = Mutex(),
) {
    private val interactiveWaiters = MutableStateFlow(0)
    private val activeDownloads = MutableStateFlow(0)

    suspend fun <T> withInteractivePriority(block: suspend () -> T): T {
        interactiveWaiters.update { it + 1 }
        try {
            return block()
        } finally {
            interactiveWaiters.update { it - 1 }
        }
    }

    suspend fun <T> withInteractive(block: suspend () -> T): T =
        withInteractivePriority { mutex.withLock { block() } }

    suspend fun <T> withTransferSlice(block: suspend () -> T): T {
        while (true) {
            interactiveWaiters.first { it == 0 }
            mutex.lock()
            if (interactiveWaiters.value == 0) {
                try {
                    return block()
                } finally {
                    mutex.unlock()
                }
            }
            mutex.unlock()
        }
    }

    /**
     * 登记一整个协议下载，而不是某一个分块。下载在块间释放 [mutex] 时仍保持登记，
     * 让只应在空闲期执行的连接探测不会误插入下一块之前。
     */
    suspend fun <T> withDownloadActivity(block: suspend () -> T): T {
        activeDownloads.update { it + 1 }
        try {
            return block()
        } finally {
            activeDownloads.update { (it - 1).coerceAtLeast(0) }
        }
    }

    /**
     * 只在没有协议下载时执行普通命令。锁外快速判断避免无意义排队；拿到锁后必须再次
     * 判断，封住“心跳先判断空闲、下载随后开始、心跳排到某个分块后面”的竞态窗口。
     */
    suspend fun <T> withIdleCommand(skippedValue: T, block: suspend () -> T): T {
        if (activeDownloads.value > 0) return skippedValue
        return mutex.withLock {
            if (activeDownloads.value > 0) skippedValue else block()
        }
    }
}

internal fun shouldUsePartialObjectDownload(
    partialObjectSupported: Boolean?,
    effectiveSize: Long,
): Boolean = partialObjectSupported != false &&
    effectiveSize > 0L && effectiveSize != PtpConstants.SIZE_UNKNOWN

internal fun downloadChunkSize(effectiveSize: Long, isUsbConnection: Boolean = false): Long =
    if (isUsbConnection) {
        NikonCamera.USB_CHUNK_SIZE
    } else if (effectiveSize > NikonCamera.LARGE_FILE_THRESHOLD) {
        NikonCamera.LARGE_FILE_CHUNK_SIZE
    } else {
        NikonCamera.CHUNK_SIZE
    }

internal fun endToEndBytesPerSecond(
    transferredBytes: Long,
    elapsedMs: Long,
): Long {
    if (transferredBytes <= 0L || elapsedMs <= 0L) return 0L
    return (transferredBytes.toDouble() * 1_000.0 / elapsedMs.toDouble())
        .toLong()
        .coerceAtLeast(0L)
}

internal fun transferredBytesThisAttempt(downloaded: Long, resumeOffset: Long): Long =
    (downloaded - resumeOffset).coerceAtLeast(0L)

class NikonCamera(private val context: Context) {
    private var cmdSocket: Socket? = null
    private var evtSocket: Socket? = null
    private var cmdInput: java.io.InputStream? = null
    private var evtInput: java.io.InputStream? = null
    private var cmdOutput: OutputStream? = null
    private var usbPtp: UsbPtpConnection? = null
    private var connectedUsbManager: UsbManager? = null
    private var connectedUsbDevice: UsbDevice? = null
    private var tid = 0
    private val cmdReader = PacketReader(context)
    private val evtReader = PacketReader(context)
    private var evtThread: Thread? = null
    // internal 而非 private:遥控实验(RemoteLab.kt)以扩展函数复用同一互斥与收发原语,
    // 保证实验命令与传输/缩略图/心跳严格串行,不引入第二条 IO 路径。
    private val ioGate = CameraIoGate()
    internal val ioMutex: Mutex
        get() = ioGate.mutex
    // 一次自动对焦由多条独立 PTP 事务组成。对焦流程和普通遥控命令仍须严格串行，
    // 只有 Live View 取帧绕过此锁；因此不会为了释放 ioMutex 引入参数/拍摄命令穿插。
    internal val focusMutex = Mutex()
    // 会话是否已 OpenSession 成功；用于决定 close() 是否需要发送 CloseSession，
    // 避免在握手中途失败时空等 CloseSession 响应（最长可达 soTimeout）。
    @Volatile private var sessionOpen = false
    // Nikon GetPartialObjectEx (0x9431) 支持探测：null=未探测, true=支持, false=不支持。
    // 仅首块明确返回 Operation_Not_Supported 时置 false 并回退全量；瞬时错误不熔断。
    // 标准 PTP 0x101B 在 Nikon 机身上不被识别，须用此专有操作码。
    @Volatile private var partialObjectSupported: Boolean? = null
    // FHD 预览(0x920F)支持探测：null=未知, true=支持, false=明确不支持。
    // 只有标准 Operation_Not_Supported 才能整会话熔断；DeviceBusy 等暂态响应不得污染
    // 能力状态。一次成功后保持 true，避免后续单个 handle 的异常推翻已验证能力。
    // 每次 connect 新建 NikonCamera 实例，故换相机自动重新探测。仅 ioMutex 内访问。
    @Volatile private var fhdSupported: Boolean? = null
    // 遥控监看的取帧操作码：首次取帧从 DeviceInfo 解析并缓存。
    // 新机优先 0x9428（带 Display Information Data），不支持时回退 0x9203。
    // 每次连接都会新建 NikonCamera，因此不会把上一台机身的判断带进新会话。
    @Volatile internal var liveViewImageOperation: Int? = null
    // StartLiveView 后最后一次 DeviceReady 轮询完成的时刻。USB 监看用它补足机身
    // 传感器/编码器的启动预热窗口；即使页面先读取参数再接管已开启的 LV，也只等待
    // 尚未覆盖的那部分时间，不会重复写死一整段延迟。
    @Volatile internal var liveViewReadyAtElapsedMs = 0L
    // Nikon 主体追踪操作码（StartTracking/EndTracking）的会话级能力与生命周期。
    // null=尚未实际尝试，false=明确返回 Operation_Not_Supported；瞬时错误不熔断。
    // 两个字段只在 focusMutex 内读写；实际 Start/End 命令再按 focusMutex -> ioMutex 串行。
    internal var subjectTrackingSupported: Boolean? = null
    internal var subjectTrackingActive = false
    // 增强取帧偶发空/坏帧不能等同于“不支持”；连续两次才降级，成功即清零。
    // 仅在 ioMutex 内访问。
    internal var liveViewEnhancedFailureCount = 0
    // 远程录像兼容模式的成对记账放在连接对象上，而不是 Compose 页面里：
    // 横竖屏重建或离开后重进监看页时仍能正确停止录像并恢复相机状态；
    // 断线会创建新的 NikonCamera，自然不会把旧连接的记账带过去。
    @Volatile internal var remoteMovieApplicationPropSet = false
    @Volatile internal var remoteMovieApplicationOpSet = false
    // USB 录像期间持有的尼康完整远控模式（0x90C2）。开录前设 1，停录回待机时
    // 成对清 0；放在连接对象上可跨横竖屏重建记账，断线换实例则自然清空。
    @Volatile internal var remoteControlModeSet = false
    val connectionType: CameraConnectionType
        get() = if (usbPtp != null) CameraConnectionType.USB else CameraConnectionType.WIFI

    companion object {
        const val TAG = "ZTransfer"
        // 命令/事件通道的常规读超时。
        const val SO_TIMEOUT_MS = 60_000
        private const val USB_CONNECT_TIMEOUT_MS = 5_000
        // 仅给 Android USB Host 释放接口留一个调度窗口。真机验证表明更长的固定等待
        // 不会改善首次取帧，反而让页面看起来冻结。
        internal const val USB_REMOTE_REOPEN_SETTLE_MS = 100L
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
        // 所有大小已知的文件都优先走 GetPartialObjectEx。USB 固定每块 64MB，避免有线
        // 模式反复承担相机准备/命令往返；Wi-Fi 普通文件使用 4MB，超过
        // LARGE_FILE_THRESHOLD 的巨大文件为 32MB。
        // 每块仍是独立 PTP 事务，块间释放相机通道供当前 FHD / EXIF 使用。
        // 也是断点续传的检查点粒度；旧版本留下的 64MB 对齐半成品仍天然兼容。
        // internal: TransferViewModel 引用此值做续传偏移对齐。
        const val CHUNK_SIZE = 4L * 1024 * 1024
        /** USB avoids repeated camera-side PartialObject setup; Wi-Fi keeps its existing policy. */
        const val USB_CHUNK_SIZE = 64L * 1024 * 1024
        const val LARGE_FILE_THRESHOLD = 512L * 1024 * 1024
        const val LARGE_FILE_CHUNK_SIZE = 32L * 1024 * 1024
        private const val FHD_DEVICE_BUSY_RETRIES = 2
        private const val FHD_DEVICE_BUSY_RETRY_DELAY_MS = 160L
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
            if (FileOrderProbe.enabled) FileOrderProbe.beginConnection("PTP/IP")
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
                    if (ack.type == PtpConstants.INIT_FAIL) CameraRefusedException(
                        context.getString(R.string.error_camera_refused)
                    )
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

            if (FileOrderProbe.enabled) {
                try {
                    sendCmd(PtpConstants.GET_DEVICE_INFO)
                    val (deviceInfoResp, deviceInfoData) = recvRespWithPayload()
                    if (deviceInfoResp == PtpConstants.RESPONSE_OK && deviceInfoData != null) {
                        val info = parseDeviceInfo(deviceInfoData)
                        FileOrderProbe.recordCapabilities(
                            manufacturer = info.manufacturer,
                            model = info.model,
                            deviceVersion = info.deviceVersion,
                            operations = info.operations,
                        )
                    } else {
                        FileOrderProbe.recordCapabilityFailure(
                            "response=0x${deviceInfoResp.toString(16)} data=${deviceInfoData?.size ?: 0}B"
                        )
                    }
                } catch (e: Exception) {
                    FileOrderProbe.recordCapabilityFailure(
                        "${e.javaClass.simpleName}: ${e.message.orEmpty()}"
                    )
                }
            }

            startEvtThread()

            Result.success(Unit)
        } catch (e: Exception) {
            close()
            Result.failure(e)
        }
    }

    /** Opens a raw PTP session over an Android USB Host connection. */
    suspend fun connectUsb(
        manager: UsbManager,
        device: UsbDevice
    ): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            if (FileOrderProbe.enabled) FileOrderProbe.beginConnection("USB")
            log { "USB_CONNECT open device=${device.deviceName}" }
            tid = -1
            val transport = UsbPtpConnection.open(manager, device).getOrThrow()
            usbPtp = transport
            transport.readTimeoutMs = USB_CONNECT_TIMEOUT_MS

            // Android 原生 MTP host 会先以 transaction 0 打开会话，
            // 再从 transaction 1 开始读取 DeviceInfo 并执行后续操作。
            log { "USB_CONNECT open-session" }
            sendCmd(PtpConstants.OPEN_SESSION, 1)
            val resp = recvResp()
            log { "USB_CONNECT open-session response=0x${resp.toString(16)}" }
            if (resp != PtpConstants.RESPONSE_OK && resp != PtpConstants.SESSION_ALREADY_OPEN) {
                throw Exception(
                    context.getString(
                        R.string.error_open_session,
                        PtpConstants.translateResponse(context, resp)
                    )
                )
            }
            sessionOpen = true

            log { "USB_CONNECT device-info" }
            sendCmd(PtpConstants.GET_DEVICE_INFO)
            val (deviceInfoResp, deviceInfoData) = recvRespWithPayload()
            log { "USB_CONNECT device-info response=0x${deviceInfoResp.toString(16)}" }
            if (deviceInfoResp != PtpConstants.RESPONSE_OK) {
                throw Exception(
                    context.getString(
                        R.string.error_read_device_info,
                        PtpConstants.translateResponse(context, deviceInfoResp)
                    )
                )
            }
            if (FileOrderProbe.enabled) {
                if (deviceInfoData != null) {
                    runCatching { parseDeviceInfo(deviceInfoData) }
                        .onSuccess { info ->
                            FileOrderProbe.recordCapabilities(
                                manufacturer = info.manufacturer,
                                model = info.model,
                                deviceVersion = info.deviceVersion,
                                operations = info.operations,
                            )
                        }
                        .onFailure { error ->
                            FileOrderProbe.recordCapabilityFailure(
                                "${error.javaClass.simpleName}: ${error.message.orEmpty()}"
                            )
                        }
                } else {
                    FileOrderProbe.recordCapabilityFailure("response OK but payload is empty")
                }
            }

            transport.readTimeoutMs = SO_TIMEOUT_MS
            connectedUsbManager = manager
            connectedUsbDevice = device
            log { "USB_CONNECT ready" }
            Result.success(Unit)
        } catch (e: Exception) {
            log { "USB_CONNECT failed: ${e.javaClass.simpleName}: ${e.message}" }
            close()
            Result.failure(e)
        }
    }

    /**
     * Replaces the media-browsing PTP session with a fresh USB remote-control session.
     *
     * Nikon's USB tethering path requires a newly opened session, drains GetEventEx once,
     * then reads DeviceInfo before entering control mode. A stale OpenSession is explicitly
     * closed and retried on a new UsbDeviceConnection.
     */
    internal suspend fun refreshUsbRemoteSession(): String =
        ioMutex.withLock {
            withContext(Dispatchers.IO) {
                val manager = connectedUsbManager
                    ?: throw IllegalStateException("USB manager unavailable")
                val device = connectedUsbDevice
                    ?: throw IllegalStateException("USB device unavailable")

                if (sessionOpen) {
                    runCatching {
                        sendCmd(PtpConstants.CLOSE_SESSION)
                        recvResp()
                    }
                    sessionOpen = false
                }
                runCatching { usbPtp?.close() }
                usbPtp = null
                val settleStartedAt = SystemClock.elapsedRealtime()
                val reopenSettleMs = USB_REMOTE_REOPEN_SETTLE_MS
                log { "USB_REMOTE settling before fresh session ${reopenSettleMs}ms" }
                kotlinx.coroutines.delay(reopenSettleMs)

                var openResponse = -1
                repeat(2) { attempt ->
                    val transport = UsbPtpConnection.open(manager, device).getOrThrow()
                    usbPtp = transport
                    transport.readTimeoutMs = USB_CONNECT_TIMEOUT_MS
                    // The verified Nikon remote trace starts its fresh session at transaction 1.
                    tid = 0

                    sendCmd(PtpConstants.OPEN_SESSION, 1)
                    openResponse = recvResp()
                    if (openResponse == PtpConstants.SESSION_ALREADY_OPEN) {
                        runCatching {
                            sendCmd(PtpConstants.CLOSE_SESSION)
                            recvResp()
                        }
                        runCatching { transport.close() }
                        usbPtp = null
                        if (attempt == 0) {
                            kotlinx.coroutines.delay(USB_REMOTE_REOPEN_SETTLE_MS)
                        }
                    } else {
                        if (openResponse != PtpConstants.RESPONSE_OK) {
                            throw IllegalStateException(
                                "OpenSession response=0x%04X".format(openResponse)
                            )
                        }
                        sessionOpen = true

                        sendCmd(0x941C) // Nikon GetEventEx: drain stale events after OpenSession.
                        val drainResponse = recvRespWithPayload().first

                        sendCmd(PtpConstants.GET_DEVICE_INFO)
                        val (deviceInfoResponse, deviceInfoData) = recvRespWithPayload()
                        if (deviceInfoResponse != PtpConstants.RESPONSE_OK) {
                            throw IllegalStateException(
                                "GetDeviceInfo response=0x%04X".format(deviceInfoResponse)
                            )
                        }
                        liveViewImageOperation =
                            if (deviceInfoData != null &&
                                runCatching {
                                    0x9428 in parseDeviceInfo(deviceInfoData).operations
                                }.getOrDefault(false)
                            ) {
                                0x9428
                            } else {
                                0x9203
                            }
                        val eventReaderStarted = transport.startEventReader()

                        transport.readTimeoutMs = SO_TIMEOUT_MS
                        remoteControlModeSet = false
                        remoteMovieApplicationPropSet = false
                        remoteMovieApplicationOpSet = false
                        return@withContext buildString {
                            append("session=0x%04X".format(openResponse))
                            append(" drain=0x%04X".format(drainResponse))
                            append(" info=0x%04X".format(deviceInfoResponse))
                            append(" irq=").append(if (eventReaderStarted) "Y" else "N")
                            append(" settle=").append(reopenSettleMs).append("/")
                                .append(SystemClock.elapsedRealtime() - settleStartedAt)
                                .append("ms")
                        }
                    }
                }

                throw IllegalStateException(
                    "Fresh OpenSession response=0x%04X".format(openResponse)
                )
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

    suspend fun keepalive(): Boolean = ioGate.withIdleCommand(skippedValue = true) {
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
        val captureDate: String?,
        /** 机内"保护"(🔑)标记（ObjectInfo ProtectionStatus ≠ 0）。摄影师机内选片的常用手段。 */
        val isProtected: Boolean = false,
        /** 文件所在的 PTP StorageID；备份模式去重后可能同时属于两张卡。 */
        val storageIds: Set<Int> = emptySet(),
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

    /**
     * 获取 FHD (1920×1080) 预览图 JPEG 字节。与 [getThumbnail] 共用 [ioMutex] 串行化。
     * 仅相机明确返回“不支持”时才记住该会话无 FHD 能力；忙、对象异常和空数据都按临时失败处理。
     * 临时失败返回 null，调用方静默回退到缩略图，不影响后续照片再次尝试。
     */
    suspend fun getFhdPicture(
        handle: Int,
        retryDeviceBusy: Boolean = true,
    ): ByteArray? = ioGate.withInteractive {
        withContext(Dispatchers.IO) {
            val startedAt = android.os.SystemClock.elapsedRealtime()
            // 已判定不支持：直接返回，免去每页一次注定失败的往返（预览秒回退缩略图）。
            if (fhdSupported == false) return@withContext null
            try {
                var busyRetriesRemaining = if (retryDeviceBusy) FHD_DEVICE_BUSY_RETRIES else 0
                var result: ByteArray? = null
                requestLoop@ while (true) {
                    sendCmd(PtpConstants.NK_GET_FHD_PICTURE, handle)
                    val (respCode, data) = recvRespWithPayload()
                    val disposition = classifyFhdResponse(respCode, data?.isNotEmpty() == true)
                    fhdSupported = updateFhdSupport(fhdSupported, disposition)
                    when (disposition) {
                        FhdResponseDisposition.SUCCESS -> {
                            val payload = checkNotNull(data)
                            log {
                                "GetFhdPicture handle=$handle bytes=${payload.size} " +
                                    "network=${android.os.SystemClock.elapsedRealtime() - startedAt}ms"
                            }
                            result = payload
                            break@requestLoop
                        }
                        FhdResponseDisposition.UNSUPPORTED -> {
                            // 已经成功过的会话不因单个对象的异常响应推翻能力；未知状态下收到
                            // 标准不支持才熔断。
                            log {
                                "GetFhdPicture unsupported (resp=0x${respCode.toString(16)}), " +
                                    "latched=${fhdSupported == false}"
                            }
                            break@requestLoop
                        }
                        FhdResponseDisposition.TRANSIENT_FAILURE -> {
                            if (respCode == PtpConstants.DEVICE_BUSY && busyRetriesRemaining > 0) {
                                busyRetriesRemaining--
                                log {
                                    "GetFhdPicture busy handle=$handle, retrying " +
                                        "remaining=$busyRetriesRemaining"
                                }
                                delay(FHD_DEVICE_BUSY_RETRY_DELAY_MS)
                                continue
                            }
                            log {
                                "GetFhdPicture transient handle=$handle " +
                                    "resp=0x${respCode.toString(16)} bytes=${data?.size ?: 0}"
                            }
                            break@requestLoop
                        }
                    }
                }
                result
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // 未完整收完响应的连接不可再复用，否则下一条命令可能读到本事务残包。
                log { "GetFhdPicture transport failed: ${e.javaClass.simpleName}: ${e.message}" }
                closeQuietly()
                null
            }
        }
    }

    /**
     * 下载文件头若干字节用于 EXIF 解析。通过 [NK_GET_PARTIAL_OBJECT_EX] 从偏移 0 读取
     * [maxSize] 字节（默认 128KB，足以覆盖绝大多数 JPEG 的 EXIF 段）；与 [ioMutex]
     * 串行化。任何失败返回 null——EXIF 是纯体验增强，不应为失败产生视觉噪音。
     */
    suspend fun readExifHeader(handle: Int, maxSize: Int = 128 * 1024): ByteArray? =
        ioGate.withInteractive {
            withContext(Dispatchers.IO) {
                try {
                    sendCmd(PtpConstants.NK_GET_PARTIAL_OBJECT_EX, handle, 0, 0, maxSize, 0)
                    val (respCode, data) = recvRespWithPayload()
                    if (respCode == PtpConstants.RESPONSE_OK && data != null && data.isNotEmpty()) data
                    else {
                        log { "ReadExifHeader handle=$handle resp=0x${respCode.toString(16)} len=${data?.size ?: 0}" }
                        null
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    log { "ReadExifHeader transport failed: ${e.javaClass.simpleName}: ${e.message}" }
                    closeQuietly()
                    null
                }
            }
        }

    /**
     * 为当前大图的 FHD + EXIF 组合保留交互优先级，但不持续占用 [ioMutex]：两项之间的
     * 手机解码仍可并行进行，只是不允许原片传输抢先开始下一块。
     */
    internal suspend fun <T> withInteractivePreviewPriority(block: suspend () -> T): T =
        ioGate.withInteractivePriority(block)

    suspend fun streamFileInfo(
        handles: List<Int>,
        batchSize: Int = 20,
        onBatch: suspend (List<FileInfo>, Int, Int) -> Unit
    ) = withContext(Dispatchers.IO) {
        val loadContext = coroutineContext
        val total = handles.size
        var loaded = 0
        handles.chunked(batchSize).forEach { batch ->
            val probeStartedAtMs = if (FileOrderProbe.enabled) SystemClock.elapsedRealtime() else 0L
            // 每批单独持锁，批间释放 ioMutex：缩略图模式下缩略图请求可在批间插入，
            // 从而随列表一起渐进出图，而不是等整份列表加载完才开始。
            // 批内每个 ObjectInfo 之间也检查取消：进入监看时最多等当前一条事务收尾，
            // 不会被余下 19 条已经开始的整批扫描挡住。
            // IO 异常（掉线/读超时）直接向上抛给调用方终止扫描：逐个 handle 硬试会让
            // 每个都等满 60s 读超时、扫描假死数十分钟；单文件 PTP 级失败在
            // getObjectInfoInternal 内已按 null 跳过，不会走到这里。
            val files = ioMutex.withLock {
                batch.mapNotNull { handle ->
                    loadContext.ensureActive()
                    getObjectInfoInternal(handle)
                }
            }
            if (FileOrderProbe.enabled) {
                FileOrderProbe.recordObjectInfoBatch(
                    requestedHandles = batch,
                    files = files,
                    elapsedMs = SystemClock.elapsedRealtime() - probeStartedAtMs,
                )
            }
            loaded += files.size
            if (files.isNotEmpty()) {
                onBatch(files, loaded, total)
            }
        }
    }

    /**
     * 双卡 ObjectInfo 流式归并。每组 handle 已按各自卡内的新到旧排列；这里只为每张卡
     * 保留一个已读取的 head，用其真实 captureDate 选择全机下一条。因此不会先扫完一张卡，
     * 也不需要把全部 ObjectInfo 读完才显示。每个 handle 仍只请求一次，每次持锁最多
     * 读取 [batchSize] 条 ObjectInfo 便释放 [ioMutex]，与单卡枚举的通道占用粒度一致。
     */
    suspend fun streamMergedFileInfo(
        newestFirstHandlesByStorage: List<List<Int>>,
        batchSize: Int = 20,
        onBatch: suspend (List<FileInfo>, Int, Int) -> Unit,
    ) = withContext(Dispatchers.IO) {
        require(batchSize > 0) { "batchSize must be positive" }
        val groups = newestFirstHandlesByStorage.filter { it.isNotEmpty() }
        if (groups.isEmpty()) return@withContext

        val loadContext = coroutineContext
        val total = groups.sumOf { it.size }
        val cursors = IntArray(groups.size)
        val heads = MutableList<FileInfo?>(groups.size) { null }
        var completed = 0

        while (completed < total) {
            val requestedHandles = ArrayList<Int>(batchSize)
            val observedFiles = ArrayList<FileInfo>(batchSize)
            val probeStartedAtMs = if (FileOrderProbe.enabled) SystemClock.elapsedRealtime() else 0L
            val completedBeforeBatch = completed

            val output = ioMutex.withLock {
                var objectInfoRequests = 0
                buildList {
                    while (size < batchSize && completed < total) {
                        groups.indices.forEach { groupIndex ->
                            if (heads[groupIndex] != null) return@forEach
                            val handles = groups[groupIndex]
                            while (cursors[groupIndex] < handles.size) {
                                if (objectInfoRequests >= batchSize) return@forEach
                                loadContext.ensureActive()
                                val handle = handles[cursors[groupIndex]++]
                                objectInfoRequests++
                                requestedHandles += handle
                                val file = getObjectInfoInternal(handle)
                                if (file == null) {
                                    completed++
                                } else {
                                    observedFiles += file
                                    heads[groupIndex] = file
                                    break
                                }
                            }
                        }

                        // 还有一张卡的下一个文件尚未读到时，不能拿其它卡的旧 head 先输出，
                        // 否则跨卡顺序失去依据。请求预算用完就先释放锁，下批补齐 head。
                        val hasUnresolvedGroup = groups.indices.any { groupIndex ->
                            heads[groupIndex] == null &&
                                cursors[groupIndex] < groups[groupIndex].size
                        }
                        if (hasUnresolvedGroup) break

                        val selected = selectNewestFileHeadIndex(heads) ?: break
                        add(checkNotNull(heads[selected]))
                        heads[selected] = null
                        completed++
                    }
                }
            }

            if (FileOrderProbe.enabled && requestedHandles.isNotEmpty()) {
                FileOrderProbe.recordObjectInfoBatch(
                    requestedHandles = requestedHandles,
                    files = observedFiles,
                    elapsedMs = SystemClock.elapsedRealtime() - probeStartedAtMs,
                )
            }
            if (output.isNotEmpty()) {
                onBatch(output, completed, total)
            } else if (completed == completedBeforeBatch && requestedHandles.isEmpty()) {
                error("Merged ObjectInfo scan made no progress")
            }
        }
    }

    internal fun getObjectInfoInternal(handle: Int): FileInfo? {
        sendCmd(PtpConstants.GET_OBJECT_INFO, handle)
        val (respCode, data) = recvRespWithPayload()
        if (respCode != PtpConstants.RESPONSE_OK || data == null || data.size < 53) {
            return null
        }

        val storageId = data.getIntLE(0)
        val format = data.getUShortLE(4)
        // 关联对象（0x3001 = 文件夹）不是文件，一律不收录：常见机型的全量枚举可能不含它，
        // 但换卡/目录滚动时相机新建文件夹会带 ObjectAdded 事件，实时新增路径必须拦住，
        // 否则列表会冒出一个 0 字节的"100NIKON"条目。
        if (format == 0x3001) return null
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

        // ProtectionStatus(偏移 6,u16) 与文件同载荷,解析零额外流量。
        //（ObjectInfo 里还有两组刻意不用的字段:SequenceNumber(48)——机型可能恒填 0、
        // 语义不统一,连拍检测走"文件编号 + 秒级时间戳"的自有算法(computeBurstHandles);
        // ImagePixWidth/Height(26/30)——竖拍存的也是传感器原生横向像素,方向只在
        // EXIF Orientation 里且依赖机内"自动旋转图像"设置,判不出构图。）
        val isProtected = data.getUShortLE(6) != 0

        return FileInfo(
            handle = handle,
            size = size,
            fileName = fileName,
            captureDate = captureDate,
            isProtected = isProtected,
            storageIds = if (storageId == 0 || storageId == -1) emptySet() else setOf(storageId),
        )
    }

    data class DownloadProgress(
        val downloaded: Long,
        val total: Long,
        val bytesPerSecond: Long,
    )

    /** 查询 >4GB 文件的真实大小；仅由下载事务在相机通道保护内调用。 */
    private fun getObjectSizeInternal(handle: Int): Long? {
        sendCmd(PtpConstants.NK_GET_OBJECT_SIZE, handle)
        val (respCode, data) = recvRespWithPayload()
        if (respCode != PtpConstants.RESPONSE_OK || data == null || data.size < 8) {
            log { "GetObjectSize failed: resp=0x${respCode.toString(16)}" }
            return null
        }
        val size = data.getLongLE(0)
        log { "GetObjectSize handle=$handle size=$size" }
        return if (size > 0) size else null
    }

    /** 单文件下载完成后的统计；速度由保存层按同一端到端时间范围计算。 */
    data class DownloadStats(
        val bytes: Long,
        /** 本次实际从相机读取的字节数，不包含续传前已经存在的部分。 */
        val transferredBytes: Long,
        /** 本文件进入协议下载流程的单调时钟时间戳（包含块间让路时间）。 */
        val startedAtElapsedMs: Long
    )

    /**
     * 下载文件到 [output]。[totalSize] 为 ObjectInfo 中的文件大小（0/SIZE_UNKNOWN=未知）；
     * [resumeOffset] 非零时从该偏移续传（调用方须已把 output 定位到该偏移）。
     *
     * 两条数据相位路径共用同一个 [pump] 循环，只是驱动它的命令不同：
     * - 分块（GetPartialObjectEx）：所有大小已知且机型支持的文件；每块是完整 PTP 事务，
     *   块间释放通道供 FHD / EXIF 插入，并按【实收字节】推进偏移。
     * - 全量（GetObject）：仅 resumeOffset==0 且分块不支持或大小未知时回退。
     *
     * 续传是一等契约：若请求了 resumeOffset 但走不了分块（相机不支持 / 大小未知），
     * 绝不用"从 0 全量"去填一个已定位到偏移的流（会写出错位的损坏文件），而是抛
     * [ResumeUnavailableException] 让调用方删半成品重下。
     */
    suspend fun downloadToFile(
        handle: Int,
        output: OutputStream,
        onProgress: ((DownloadProgress) -> Unit)? = null,
        resumeOffset: Long = 0L,
        totalSize: Long = 0L
    ): Result<DownloadStats> = ioGate.withDownloadActivity {
        withContext(Dispatchers.IO) {
            val scope = this
            var totalDownloaded = resumeOffset
            // 从任务真正进入协议层开始计时；相机准备、分块事务、写入，以及分块之间为
            // FHD / EXIF 让路的时间都属于用户实际等待时间，实时速度必须使用这条时间线。
            val startTime = android.os.SystemClock.elapsedRealtime()
            var lastProgressTime = startTime

            fun buildStats(): DownloadStats {
                return DownloadStats(
                    bytes = totalDownloaded,
                    transferredBytes = transferredBytesThisAttempt(totalDownloaded, resumeOffset),
                    startedAtElapsedMs = startTime,
                )
            }

            fun progressSnapshot(total: Long, now: Long) =
                DownloadProgress(
                    downloaded = totalDownloaded,
                    total = total,
                    bytesPerSecond = endToEndBytesPerSecond(
                        transferredBytes = transferredBytesThisAttempt(totalDownloaded, resumeOffset),
                        elapsedMs = now - startTime,
                    ),
                )

            fun emitProgress(total: Long, force: Boolean = false) {
                val now = android.os.SystemClock.elapsedRealtime()
                if (force || now - lastProgressTime >= 200L) {
                    onProgress?.invoke(progressSnapshot(total, now))
                    lastProgressTime = now
                }
            }
            fun incomplete(got: Long, want: Long) =
                Result.failure<DownloadStats>(Exception(context.getString(R.string.error_incomplete_data, got, want)))
            fun failed(respCode: Int) =
                Result.failure<DownloadStats>(Exception(
                    context.getString(R.string.error_transfer_failed_reason, PtpConstants.translateResponse(context, respCode))))

            // 读取一个完整的 PTP 数据相位（直到并【消费掉】CMD_RESPONSE），data 段经 output 写出。
            // 返回 (响应码, 本相位写出的字节数, START_DATA 声明的长度或 -1)。
            // 循环到 CMD_RESPONSE 为止——END_DATA 只当作最后一个 data 包，响应包必被读走，
            // 不再遗留污染下一事务。本地写盘失败抛 OutputWriteException（由外层归为单文件失败）。
            fun pump(progressTotalHint: Long): Triple<Int, Long, Long> {
                usbPtp?.let { usb ->
                    val total = if (progressTotalHint > 0) progressTotalHint else 0L
                    val result = usb.receiveDataTo(
                        expectedTransactionId = tid,
                        onDataStart = { emitProgress(total, force = true) },
                    ) { bytes, offset, count ->
                        scope.ensureActive()
                        try {
                            output.write(bytes, offset, count)
                        } catch (e: java.io.IOException) {
                            throw OutputWriteException(context.getString(R.string.error_write_file, e.message), e)
                        }
                        totalDownloaded += count
                        emitProgress(total)
                    }
                    return Triple(result.responseCode, result.written, result.expected)
                }

                var expected = -1L
                var written = 0L
                while (true) {
                    scope.ensureActive()
                    val packet = cmdReader.readPacketRaw(cmdInput!!)
                    val buf = packet.buffer
                    val len = packet.payloadLen
                    when (packet.type) {
                        PtpConstants.CMD_RESPONSE ->
                            return Triple(if (len >= 2) buf.getUShortLE(0) else 0, written, expected)
                        PtpConstants.START_DATA_PACKET -> {
                            expected = when {
                                len >= 12 -> buf.getLongLE(4)
                                len >= 8 -> buf.getIntLE(4).toLong() and 0xFFFFFFFFL
                                else -> 0L
                            }
                            val total = if (progressTotalHint > 0) progressTotalHint else expected
                            emitProgress(total, force = true)
                        }
                        PtpConstants.DATA_PACKET, PtpConstants.END_DATA_PACKET -> {
                            if (len > 4) {
                                try {
                                    output.write(buf, 4, len - 4)
                                } catch (e: java.io.IOException) {
                                    throw OutputWriteException(context.getString(R.string.error_write_file, e.message), e)
                                }
                                written += len - 4
                                totalDownloaded += len - 4
                                val total = if (progressTotalHint > 0) progressTotalHint else expected
                                emitProgress(total)
                            }
                        }
                        PtpConstants.PING -> sendPong(cmdOutput)
                    }
                }
            }

            // 事务异常共用：发 Cancel 请求相机停发 → 收紧超时排空在途数据 → 保住连接或兜底断开。
            suspend fun abortActiveTransaction() {
                if (usbPtp != null) {
                    // An aborted transaction may stop in the middle of a single USB data container.
                    // The next 12 bytes are therefore not guaranteed to be a container header;
                    // closing is the only safe way to avoid reusing a desynchronised PTP stream.
                    closeQuietly()
                    return
                }
                try {
                    withContext(NonCancellable) {
                        sendCancel()
                        cmdSocket?.soTimeout = CANCEL_DRAIN_TIMEOUT_MS
                        if (drainCmdResponse(CANCEL_DRAIN_BUDGET)) {
                            cmdSocket?.soTimeout = SO_TIMEOUT_MS
                        } else {
                            log { "DL_ABORT drain budget exceeded, closing" }
                            closeQuietly()
                        }
                    }
                } catch (_: Exception) {
                    closeQuietly()
                }
            }

            // 一个完整下载事务的安全边界。任何异常若发生在数据相位内，都必须仍持有
            // 通道锁完成 Cancel/排空；否则下一条 FHD/EXIF 可能读到上一事务遗留的数据包。
            suspend fun <T> transferTransaction(block: suspend () -> T): T =
                ioGate.withTransferSlice {
                    try {
                        block()
                    } catch (e: Exception) {
                        abortActiveTransaction()
                        throw e
                    }
                }

            try {
                // 对 >4GB 文件（ObjectInfo 报 SIZE_UNKNOWN）用 GetObjectSize 取真实 64 位大小。
                var effectiveSize = totalSize
                if (totalSize == PtpConstants.SIZE_UNKNOWN || totalSize <= 0L) {
                    transferTransaction { getObjectSizeInternal(handle) }?.takeIf { it > 0 }?.let {
                        effectiveSize = it
                        log { "DL_SIZE resolved: $totalSize -> $it via GetObjectSize" }
                    }
                }
                val sizeKnown = effectiveSize > 0L && effectiveSize != PtpConstants.SIZE_UNKNOWN
                // 普通照片也走既有分块协议；这是在 PTP 事务边界插入大图请求的前提。
                val usePartial = shouldUsePartialObjectDownload(partialObjectSupported, effectiveSize)

                // 请求了续传却走不了分块：全量只能从 0 填，会写坏已定位的流。拒绝，让调用方重下。
                if (resumeOffset > 0 && !usePartial) {
                    return@withContext Result.failure(ResumeUnavailableException())
                }

                if (usePartial) {
                    // ===== 分块路径 =====
                    var offset = resumeOffset
                    var first = true
                    var fellBack = false
                    val chunkSize = downloadChunkSize(
                        effectiveSize = effectiveSize,
                        isUsbConnection = usbPtp != null,
                    )
                    while (offset < effectiveSize) {
                        scope.ensureActive()
                        val reqSize = minOf(chunkSize, effectiveSize - offset).toInt()
                        log { "DL_CHUNK offset=$offset size=$reqSize" }
                        val (resp, got, chunkExpected) = transferTransaction {
                            sendCmd(PtpConstants.NK_GET_PARTIAL_OBJECT_EX, handle,
                                (offset and 0xFFFFFFFFL).toInt(),
                                (offset ushr 32).toInt(), reqSize, 0)
                            pump(effectiveSize)
                        }
                        log { "DL_CHUNK_RESP resp=0x${resp.toString(16)} got=$got" }

                        if (resp != PtpConstants.RESPONSE_OK) {
                            // 只有相机明确表示不支持操作码，且流仍在 0，才能安全回退全量。
                            // 设备忙等瞬时错误直接失败，绝不把当前文件降级成不可插队的整传。
                            if (first && got == 0L && resumeOffset == 0L &&
                                resp == PtpConstants.OPERATION_NOT_SUPPORTED
                            ) {
                                partialObjectSupported = false
                                fellBack = true
                                log { "DL_PARTIAL unsupported, full fallback" }
                                break
                            }
                            return@withContext failed(resp)
                        }
                        partialObjectSupported = true
                        // 逐块校验：声明长度与实收不符 = 短读，立即失败（不吞不跳）。
                        if (chunkExpected > 0 && got != chunkExpected) return@withContext incomplete(got, chunkExpected)
                        // OK 但零字节：相机不再推进，避免死循环。
                        if (got == 0L) return@withContext incomplete(totalDownloaded, effectiveSize)
                        // 按【实收字节】推进，而非请求量——短读也不会跳过未收到的区间。
                        offset += got
                        first = false
                    }
                    if (!fellBack) {
                        // 全文件完整性：分块模式的最终防线（此前只有逐块校验）。
                        if (totalDownloaded != effectiveSize) return@withContext incomplete(totalDownloaded, effectiveSize)
                        return@withContext Result.success(buildStats())
                    }
                    // fellBack：resumeOffset 必为 0，totalDownloaded 仍为 0，落入下方全量路径。
                }

                // ===== 全量路径（仅 resumeOffset==0：全新下载 或 分块不支持回退）=====
                val (resp, _, expected) = transferTransaction {
                    sendCmd(PtpConstants.GET_OBJECT, handle)
                    pump(if (sizeKnown) effectiveSize else 0L)
                }
                log { "DL_FULL resp=0x${resp.toString(16)} total=$totalDownloaded" }
                if (resp != PtpConstants.RESPONSE_OK) return@withContext failed(resp)
                // 相机异常提前结束数据阶段：声明大小与实收不符则判残缺。SIZE_UNKNOWN/未声明放行。
                if (expected > 0 && expected != PtpConstants.SIZE_UNKNOWN && totalDownloaded != expected) {
                    return@withContext incomplete(totalDownloaded, expected)
                }
                Result.success(buildStats())
            } catch (e: CancellationException) {
                // 数据相位内的取消已由 transferTransaction 在持锁状态排空；块间取消没有
                // 在途协议数据，直接传播即可。
                throw e
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

    private fun closeQuietly() {
        sessionOpen = false
        try { usbPtp?.close() } catch (_: Exception) {}
        usbPtp = null
        connectedUsbManager = null
        connectedUsbDevice = null
        try { cmdInput?.close() } catch (_: Exception) {}
        try { cmdSocket?.close() } catch (_: Exception) {}
        try { evtInput?.close() } catch (_: Exception) {}
        try { evtSocket?.close() } catch (_: Exception) {}
        evtThread?.interrupt()
        evtThread = null
    }

    /**
     * 临时修改命令通道读超时，返回原值。只允许已持有 [ioMutex] 的
     * 协议序列使用，避免其它事务观察到临时超时值。
     */
    internal fun setCommandReadTimeout(timeoutMs: Int): Int {
        usbPtp?.let {
            val previous = it.readTimeoutMs
            it.readTimeoutMs = timeoutMs.coerceAtLeast(1)
            return previous
        }
        val socket = cmdSocket ?: throw java.io.EOFException(context.getString(R.string.connection_lost))
        val previous = socket.soTimeout
        socket.soTimeout = timeoutMs.coerceAtLeast(1)
        return previous
    }

    /** 恢复 [setCommandReadTimeout] 保存的超时；连接已关闭时由调用方忽略异常。 */
    internal fun restoreCommandReadTimeout(timeoutMs: Int) {
        usbPtp?.let {
            it.readTimeoutMs = timeoutMs.coerceAtLeast(1)
            return
        }
        cmdSocket?.soTimeout = timeoutMs
    }

    /**
     * 命令包读取超时后不得继续复用该 PTP/IP 流：PacketReader 可能已读了
     * 半个包，迟到响应也会被下一事务误认。调用方必须已持有 [ioMutex]。
     */
    internal fun abortProtocolTransport() {
        closeQuietly()
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
        usbPtp?.let { usb ->
            usb.sendCommand(code, nextTid(), params)
            return
        }
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
        val t = nextTid()
        usbPtp?.let { usb ->
            usb.sendCommand(code, t, params)
            usb.sendData(code, t, data)
            return
        }
        val paramCount = params.size.coerceAtMost(5)
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
        usbPtp?.let { return it.receiveResponse(tid) }
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
        usbPtp?.let { return it.receiveResponseWithPayload(tid) }
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
