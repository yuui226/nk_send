package com.ztransfer.viewmodel

import android.app.Application
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.wifi.WifiManager
import android.os.Build
import android.os.SystemClock
import android.util.LruCache
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.exifinterface.media.ExifInterface
import com.ztransfer.diagnostics.FileOrderProbe
import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.protocol.CameraEndpointOverride
import com.ztransfer.protocol.CameraRefusedException
import com.ztransfer.protocol.Lab
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.protocol.PtpConstants
import com.ztransfer.protocol.UsbPtpConnection
import com.ztransfer.protocol.rcPollEvents
import com.ztransfer.service.CameraSessionService
import com.ztransfer.util.applyExifOrientation
import java.io.ByteArrayInputStream
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.math.roundToInt

enum class WifiConnectionStatus {
    IDLE,
    PROBING,
    NOT_FOUND,
    REFUSED,
    FAILED,
    RECONNECTING
}

internal fun classifyWifiConnectionFailure(error: Throwable): WifiConnectionStatus = when (error) {
    is CameraRefusedException -> WifiConnectionStatus.REFUSED
    is ConnectException,
    is NoRouteToHostException,
    is SocketTimeoutException -> WifiConnectionStatus.NOT_FOUND
    else -> WifiConnectionStatus.FAILED
}

private val EFFECT_PREVIEW_VIDEO_EXTENSIONS = setOf(".mov", ".mp4")

/** Selects the newest still image deterministically; video covers must never become effect demos. */
internal fun latestEffectPreviewFile(files: List<NikonCamera.FileInfo>): NikonCamera.FileInfo? =
    files.asSequence()
        .filter { it.extension !in EFFECT_PREVIEW_VIDEO_EXTENSIONS }
        .maxWithOrNull(compareBy<NikonCamera.FileInfo>({ it.captureDate.orEmpty() }, { it.handle }))

private fun NikonCamera.FileInfo.logicalIdentity(): String =
    "$fileName|$size|$captureDate"

/** 双卡备份文件仍只显示一份，但保留它在两张卡上的完整归属。 */
internal fun mergeStorageMembership(
    existing: NikonCamera.FileInfo,
    duplicate: NikonCamera.FileInfo,
): NikonCamera.FileInfo {
    if (duplicate.storageIds.all { it in existing.storageIds }) return existing
    return existing.copy(storageIds = existing.storageIds + duplicate.storageIds)
}

/**
 * PTP StorageID 高 16 位是物理存储、低 16 位是其逻辑分区。优先据此识别卡槽；
 * 对少数非标准编号，按稳定排序补进尚未占用的卡 1/2。
 */
internal fun storageIdsBySlot(storageIds: List<Int>): Map<Int, Set<Int>> {
    val result = sortedMapOf<Int, MutableSet<Int>>()
    val unassignedGroups = linkedMapOf<Int, MutableSet<Int>>()
    storageIds.distinct().sorted().forEach { storageId ->
        val physical = storageId ushr 16 and 0xFFFF
        val logical = storageId and 0xFFFF
        val slot = when {
            physical in 1..2 -> physical
            physical == 0 && logical in 1..2 -> logical
            else -> null
        }
        if (slot != null) {
            result.getOrPut(slot) { linkedSetOf() } += storageId
        } else {
            val groupKey = if (physical == 0) storageId else physical
            unassignedGroups.getOrPut(groupKey) { linkedSetOf() } += storageId
        }
    }
    unassignedGroups.values.forEach { ids ->
        val freeSlot = (1..2).firstOrNull { it !in result } ?: return@forEach
        result[freeSlot] = ids
    }
    return result.mapValues { it.value.toSet() }
}

/** 日期范围只改变优先级，不改变最终全量填充集合。范围完成后自然接回全局新→旧。 */
internal fun prioritizedThumbnailFiles(
    files: List<NikonCamera.FileInfo>,
    range: PhotoDateRange?,
): List<NikonCamera.FileInfo> {
    // Kotlin 的排序稳定：同一拍摄时间保留文件枚举时的相机自然顺序，让 JPG/RAW 配对
    // 继续相邻。不能再用 handle 打破平局，其高位在 Nikon 上含格式特征。
    val ordered = files.sortedByDescending { it.captureDate.orEmpty() }
    if (range == null) return ordered
    val prioritized = ArrayList<NikonCamera.FileInfo>(ordered.size)
    val remaining = ArrayList<NikonCamera.FileInfo>(ordered.size)
    ordered.forEach { file ->
        if (range.containsCaptureDate(file.captureDate)) prioritized += file else remaining += file
    }
    prioritized.addAll(remaining)
    return prioritized
}

/** 单个 PTP StorageID 内由新到旧的 handle 顺序；顺序来自相机原始数组的反序。 */
internal data class StorageHandleOrder(
    val storageId: Int,
    val newestFirstHandles: List<Int>,
)

/**
 * Nikon 返回的单卡 handle 数组在实机上是旧到新，并且天然把同次拍摄的 JPG/RAW、视频
 * 按拍摄顺序交错排列。只反转每张卡，不能再按 handle 数值排序：handle 高位含格式特征，
 * 数值排序会把 MP4/JPG/RAW 拆成大块。跨卡重复 handle 仍按第一张卡出现的位置保留一次。
 */
internal fun newestFirstHandleOrders(
    rawHandlesByStorage: List<Pair<Int, List<Int>>>,
): List<StorageHandleOrder> {
    val seen = HashSet<Int>()
    return rawHandlesByStorage.map { (storageId, rawHandles) ->
        StorageHandleOrder(
            storageId = storageId,
            newestFirstHandles = rawHandles.asReversed().filter { seen.add(it) },
        )
    }
}

/**
 * 一次相机会话内的整卡枚举快照。大图预览只暂停 ObjectInfo 阶段，关闭后可直接复用
 * 已经取得的每卡 handles；相机会话一旦更换，handle 不再可信，必须重新枚举。
 */
internal data class FileScanHandleSnapshot(
    val sessionToken: Any,
    val storageIds: List<Int>,
    val handleOrders: List<StorageHandleOrder>,
) {
    // 备份模式下第二张卡的副本会合并进第一条，状态列表不再保留它自己的 handle；单靠
    // existingHandles 无法知道它已读过。快照额外记住真正发布过的 handle，FHD 恢复时
    // 才不会重复读取这些已合并副本。
    private val processedHandles = HashSet<Int>()

    fun belongsTo(sessionToken: Any): Boolean = this.sessionToken === sessionToken

    val totalHandleCount: Int
        get() = handleOrders.sumOf { it.newestFirstHandles.size }

    fun markProcessed(handles: Collection<Int>) {
        synchronized(processedHandles) { processedHandles.addAll(handles) }
    }

    fun remainingAfter(existingHandles: Set<Int>): List<StorageHandleOrder> {
        val skipped = synchronized(processedHandles) {
            HashSet<Int>(existingHandles.size + processedHandles.size).apply {
                addAll(existingHandles)
                addAll(processedHandles)
            }
        }
        return handleOrders.map { order ->
            order.copy(
                newestFirstHandles = order.newestFirstHandles.filterNot { it in skipped }
            )
        }
    }
}

data class CameraState(
    /** 网关特征只表示“值得探测”，不能作为已经连上相机的依据。 */
    val isWifiCandidate: Boolean = false,
    val isConnectedToCamera: Boolean = false,
    val isConnecting: Boolean = false,
    val connectionType: CameraConnectionType? = null,
    val usbConnectionError: String? = null,
    val wifiConnectionStatus: WifiConnectionStatus = WifiConnectionStatus.IDLE,
    val files: List<NikonCamera.FileInfo> = emptyList(),
    /** 当前相机已插卡的 PTP StorageID；卡槽映射由 [storageIdsBySlot] 统一解释。 */
    val storageIds: List<Int> = emptyList(),
    val isLoadingFiles: Boolean = false,
    /** 本轮文件枚举是否完整成功；异常/暂停不能被误认为“范围内确实无照片”。 */
    val hasCompletedFileScan: Boolean = false,
    /** Latest camera still, quietly prefetched at FHD for the frame/filter settings demos. */
    val effectPreviewBitmap: Bitmap? = null,
    val effectPreviewFileKey: String? = null,
    // 当前候选 Wi-Fi 的信号强度（dBm，典型 -30 强 ~ -90 弱）；无候选链路时为 null。
    val wifiRssi: Int? = null
)

/**
 * 从相机文件头（JPEG EXIF）解析的照片参数。所有字段均可为 null——解析不到时静默缺省。
 */
data class PhotoExif(
    val aperture: String?,       // "f/2.8"
    val shutterSpeed: String?,   // "1/250"
    val iso: String?,            // "400"
    val focalLength: String?     // "50mm"
)

class CameraViewModel(application: Application) : AndroidViewModel(application) {
    private val _state = MutableStateFlow(CameraState())
    val state: StateFlow<CameraState> = _state.asStateFlow()

    private var camera: NikonCamera? = null
    private var keepaliveJob: Job? = null
    private var watcherJob: Job? = null
    private var eventPollJob: Job? = null
    private var fileLoadJob: Job? = null
    // 首次连接的整卡 ObjectInfo 枚举可能跨越数秒。进入监看时取消并记住尚未完成，
    // 退出后从已发布的文件继续，避免 GetObjectInfo 与 Live View 取帧争抢 ioMutex。
    private var fileLoadPending = false
    // ObjectInfo 开始前已经取得的 StorageID + handles 快照。大图预览短暂停顿后，同一
    // NikonCamera 实例可直接继续剩余 handles，不重复向相机请求整卡 handle 列表。
    private var fileScanHandleSnapshot: FileScanHandleSnapshot? = null
    // 每次 loadFiles 都递增；旧扫描即使在阻塞 IO 返回后才观察到取消，也不能覆盖新扫描状态。
    private var fileLoadGeneration = 0L
    private var usbPermissionJob: Job? = null
    private var usbConnectJob: Job? = null
    private var pendingUsbPermissionDeviceId: Int? = null
    private var usbConnectFailures = 0
    private var usbRetryPaused = false
    private val usbManager = application.getSystemService(Context.USB_SERVICE) as UsbManager
    private var attachedUsbDevice: UsbDevice? = null
    private var activeUsbDeviceId: Int? = null

    // 缩略图内存缓存：按位图字节数限容（约 1/8 可用内存），超限自动淘汰。
    private val thumbnailCache = object : LruCache<Int, ImageBitmap>(
        (Runtime.getRuntime().maxMemory() / 1024 / 8).toInt().coerceAtLeast(4 * 1024)
    ) {
        override fun sizeOf(key: Int, value: ImageBitmap): Int = value.width * value.height * 4 / 1024
    }
    // "确认无缩略图/解码失败"的负缓存：滚动回来不再对同一文件重发无谓的 GetThumb。
    // IO 瞬时失败（掉线等）不入内。仅主线程访问（loadThumbnail 及其 async 均跑在主调度器）。
    private val noThumbHandles = HashSet<Int>()
    // 进行中的缩略图请求：格子与长按预览并发请求同一张时共享同一次取图+解码；
    // 最后一个等待者取消时连带取消底层请求，保留"滚出屏幕即剪枝"的行为。仅主线程访问。
    private class InflightThumb(val deferred: Deferred<ImageBitmap?>) { var waiters = 0 }
    private val inflightThumbs = HashMap<Int, InflightThumb>()
    // 后台落盘先于可见格发起时也要共享请求；否则二者会在 remoteThumbGate 两侧各取一次。
    // value 只负责把字节落盘，不解码入内存，完成后由主线程清理。
    private val inflightPrefetches = HashMap<Int, CompletableDeferred<Boolean>>()
    // PTP 命令通道本身严格串行；若整屏可见格子都提前排进 NikonCamera.ioMutex，
    // 后来的交互型 FHD 会被十几个 GetThumb 挡住。这里只允许一个远程缩略图进入
    // PTP 等待队列，其余在外层等待；不降低相机吞吐，却给 FHD 留出插队机会。
    private val remoteThumbGate = Semaphore(1)
    // EXIF 缓存：键为【稳定身份】(文件名+大小+拍摄时间)，与磁盘缩略图缓存同口径——
    // 不用会话级 handle 作键，因 handle 跨会话/换卡会复用，否则重连后同一 handle 会把
    // EXIF 参数缓存。null value = 已尝试但失败（负缓存）。
    private val exifCache = HashMap<String, PhotoExif?>()

    /** EXIF 缓存键：与 [diskFile] 同一稳定身份，跨会话/重连命中同一张照片。 */
    private fun exifKey(file: NikonCamera.FileInfo): String =
        "${file.fileName}_${file.size}_${file.captureDate ?: "0"}"

    // 用于连接清理等需在 viewModelScope 取消后仍完成的一次性 IO。
    private val cleanupScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    // 缩略图磁盘缓存目录：后台填充落盘于此，内存 LRU 只服务可见区。
    private val thumbDiskDir = File(application.cacheDir, "thumbs").apply { mkdirs() }
    // 磁盘缓存文件名索引：首次使用时一次性列目录建立，写入/删除同步维护——后台填充
    // 逐张探测"是否已落盘"在内存完成，不再每张跨线程 stat（几千张跳过从数百 ms 降到微秒级）。
    // 仅主线程访问（prefetch/fetch 的续体都在主调度器）。
    private var diskIndex: HashSet<String>? = null

    private suspend fun diskIndexSet(): HashSet<String> {
        diskIndex?.let { return it }
        val names = withContext(Dispatchers.IO) {
            thumbDiskDir.list()?.toHashSet() ?: HashSet()
        }
        // 挂起期间可能已有并发首调建好索引（且其后可能已有写入），保留已建的。
        return diskIndex ?: names.also { diskIndex = it }
    }
    private val connectivityManager = application.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    @Suppress("DEPRECATION")
    private val wifiManager = application.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

    // 会话级 WifiLock：只要连着相机就持有——阻止 Wi-Fi 进省电打盹（打盹的客户端容易被
    // 相机热点踢掉，也是浏览时"容易断"的主要来源）。与 TransferService 传输期的锁互补：
    // 那把只覆盖传输窗口，这把覆盖整个会话；持锁期间用户本就在用相机，功耗可接受。
    private val sessionWifiLock: WifiManager.WifiLock = wifiManager.createWifiLock(
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        } else {
            @Suppress("DEPRECATION")
            WifiManager.WIFI_MODE_FULL_HIGH_PERF
        },
        "ZTransfer:session"
    ).apply { setReferenceCounted(false) }

    private fun acquireSessionWifiLock() {
        try {
            if (!sessionWifiLock.isHeld) sessionWifiLock.acquire()
        } catch (_: Exception) {}
    }

    private fun releaseSessionWifiLock() {
        try {
            if (sessionWifiLock.isHeld) sessionWifiLock.release()
        } catch (_: Exception) {}
    }

    // 当前 Wi-Fi 的 Network 对象：socket 必须绑定到它建连——相机热点没有互联网，
    // 系统常把默认网络留在蜂窝上，不绑定的话连接请求会进蜂窝路由黑洞干等超时。
    @Volatile
    private var wifiNetwork: Network? = null

    // LinkProperties 直接认出的"已在相机网段"：网关随 DHCP 完成即刻由系统推送，
    // 比轮询 dhcpInfo（自身还滞后于 DHCP）早 1~2 秒。与 dhcpInfo 判定取或使用。
    @Volatile
    private var linkSaysCameraWifi = false

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            wifiNetwork = network
            onWifiChanged()
        }

        override fun onLost(network: Network) {
            if (wifiNetwork == network) {
                wifiNetwork = null
                linkSaysCameraWifi = false
            }
            onWifiChanged()
        }

        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            wifiNetwork = network
            onWifiChanged()
        }

        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            wifiNetwork = network
            linkSaysCameraWifi = linkProperties.routes.any {
                it.gateway?.hostAddress == PtpConstants.CAMERA_IP
            }
            onWifiChanged()
        }
    }

    private val usbPermissionIntent: PendingIntent by lazy {
        PendingIntent.getBroadcast(
            getApplication(),
            0,
            Intent(ACTION_USB_PERMISSION).setPackage(getApplication<Application>().packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                ACTION_USB_PERMISSION -> {
                    // hasPermission() is the source of truth. Some ROMs omit one of the result
                    // extras, so fall back to the attached PTP device instead of leaving the UI
                    // indefinitely in the attached/connecting presentation.
                    val device = intent.usbDeviceExtra()
                        ?: usbManager.deviceList.values.firstOrNull {
                            UsbPtpConnection.findPtpInterface(it) != null
                        }
                        ?: return
                    if (usbManager.hasPermission(device)) {
                        usbPermissionJob?.cancel()
                        usbPermissionJob = null
                        onUsbDeviceAvailable(device)
                    } else if (intent.hasExtra(UsbManager.EXTRA_PERMISSION_GRANTED) &&
                        !intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    ) {
                        usbPermissionJob?.cancel()
                        usbPermissionJob = null
                        onUsbPermissionUnavailable(device)
                    }
                }
                UsbManager.ACTION_USB_DEVICE_ATTACHED ->
                    intent.usbDeviceExtra()?.let(::onUsbDeviceAvailable)
                UsbManager.ACTION_USB_DEVICE_DETACHED ->
                    intent.usbDeviceExtra()?.let(::onUsbDeviceDetached)
            }
        }
    }
    private var usbReceiverRegistered = false

    @Suppress("DEPRECATION")
    private fun Intent.usbDeviceExtra(): UsbDevice? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
        } else {
            getParcelableExtra(UsbManager.EXTRA_DEVICE)
        }

    private fun registerUsbReceiver() {
        if (usbReceiverRegistered) return
        val filter = IntentFilter().apply {
            addAction(ACTION_USB_PERMISSION)
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getApplication<Application>().registerReceiver(
                usbReceiver,
                filter,
                // USB attach/detach and permission completion originate outside this process.
                // The receiver still validates the device class and hasPermission() before use.
                Context.RECEIVER_EXPORTED
            )
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            getApplication<Application>().registerReceiver(usbReceiver, filter)
        }
        usbReceiverRegistered = true
    }

    private fun scanAttachedUsbCamera() {
        usbManager.deviceList.values
            .firstOrNull { UsbPtpConnection.findPtpInterface(it) != null }
            ?.let(::onUsbDeviceAvailable)
    }

    private fun onUsbDeviceAvailable(device: UsbDevice) {
        // Wi-Fi 会话期间忽略 USB 插拔；连接页识别到 PTP 设备后，本次会话锁定为 USB。
        if (_state.value.connectionType == CameraConnectionType.WIFI) return
        if (UsbPtpConnection.findPtpInterface(device) == null) return
        val isNewAttachment = attachedUsbDevice?.deviceId != device.deviceId
        if (isNewAttachment) {
            usbConnectFailures = 0
            usbRetryPaused = false
        }
        attachedUsbDevice = device
        _state.update {
            it.copy(
                connectionType = CameraConnectionType.USB,
                usbConnectionError = null,
                isWifiCandidate = false,
                wifiRssi = null,
                wifiConnectionStatus = WifiConnectionStatus.IDLE
            )
        }
        // 模式选定即释放 Wi-Fi 请求；授权等待和失败状态也不能继续占用手机网络。
        releaseWifiNetworkRequest()
        if (usbRetryPaused) return
        if (!usbManager.hasPermission(device)) {
            requestUsbPermission(device)
            return
        }
        usbPermissionJob?.cancel()
        usbPermissionJob = null
        if (pendingUsbPermissionDeviceId == device.deviceId) {
            pendingUsbPermissionDeviceId = null
        }
        connectUsbDevice(device)
    }

    private fun requestUsbPermission(device: UsbDevice) {
        if (pendingUsbPermissionDeviceId == device.deviceId) return
        pendingUsbPermissionDeviceId = device.deviceId
        _state.update {
            it.copy(
                isConnecting = true,
                usbConnectionError = null
            )
        }
        log { "USB_PERMISSION request device=${device.deviceName}" }
        val requested = runCatching {
            usbManager.requestPermission(device, usbPermissionIntent)
        }.onFailure {
            onUsbPermissionUnavailable(device)
        }.isSuccess
        if (!requested) return

        usbPermissionJob?.cancel()
        usbPermissionJob = viewModelScope.launch {
            // 部分 ROM 不可靠地回送授权广播；轮询系统权限状态仅作兜底。
            repeat((USB_PERMISSION_TIMEOUT_MS / USB_PERMISSION_POLL_MS).toInt()) {
                delay(USB_PERMISSION_POLL_MS)
                if (attachedUsbDevice?.deviceId != device.deviceId) return@launch
                if (usbManager.hasPermission(device)) {
                    pendingUsbPermissionDeviceId = null
                    usbPermissionJob = null
                    connectUsbDevice(device)
                    return@launch
                }
            }
            if (attachedUsbDevice?.deviceId == device.deviceId) {
                log { "USB_PERMISSION timeout device=${device.deviceName}" }
                onUsbPermissionUnavailable(device)
            }
        }
    }

    private fun connectUsbDevice(device: UsbDevice) {
        if (_state.value.connectionType == CameraConnectionType.WIFI) return
        if (!usbManager.hasPermission(device)) return
        if (usbRetryPaused) return
        if (_state.value.connectionType == CameraConnectionType.USB &&
            _state.value.isConnectedToCamera && activeUsbDeviceId == device.deviceId
        ) return
        if (usbConnectJob?.isActive == true) return

        usbConnectJob = viewModelScope.launch {
            try {
                _state.update {
                    it.copy(
                        isConnecting = true,
                        usbConnectionError = null
                    )
                }
                keepaliveJob?.cancel()
                eventPollJob?.cancel()
                val previous = camera
                camera = null
                previous?.close()
                releaseSessionWifiLock()
                CameraSessionService.stop(getApplication())

                val localizedContext = com.ztransfer.AppLocale.wrap(getApplication())
                val cam = NikonCamera(localizedContext)
                log { "USB_CONNECT begin device=${device.deviceName}" }
                cam.connectUsb(usbManager, device).fold(
                    onSuccess = {
                        if (attachedUsbDevice?.deviceId != device.deviceId) {
                            // OpenSession 完成前设备已变化，旧结果不可再发布。
                            cam.close()
                            val replacementAttached = attachedUsbDevice != null
                            _state.update {
                                it.copy(
                                    isConnectedToCamera = false,
                                    isConnecting = replacementAttached
                                )
                            }
                            if (replacementAttached) scheduleUsbReconnect()
                        } else {
                            usbConnectFailures = 0
                            camera = cam
                            activeUsbDeviceId = device.deviceId
                            _state.update {
                                it.copy(
                                    isConnectedToCamera = true,
                                    isConnecting = false,
                                    connectionType = CameraConnectionType.USB,
                                    usbConnectionError = null,
                                    wifiRssi = null
                                )
                            }
                            // connectedDevice 前台保活只覆盖无线 PTP 会话。有线连接由物理 USB
                            // 链路维持，不额外常驻“相机已连接”通知。
                            CameraSessionService.stop(getApplication())
                            startKeepalive()
                            loadFiles()
                            startEventPolling()
                        }
                    },
                    onFailure = { error -> handleUsbConnectFailure(device, error) }
                )
            } finally {
                usbConnectJob = null
            }
        }
    }

    private fun handleUsbConnectFailure(device: UsbDevice, error: Throwable) {
        log { "USB_CONNECT retry: ${error.javaClass.simpleName}: ${error.message}" }
        activeUsbDeviceId = null

        // 拔线导致的 I/O 失败不计入重试，也不能把断开态重新覆盖成“连接中”。
        if (attachedUsbDevice?.deviceId != device.deviceId) {
            val replacementAttached = attachedUsbDevice != null
            _state.update {
                it.copy(
                    isConnectedToCamera = false,
                    isConnecting = replacementAttached,
                    usbConnectionError = null
                )
            }
            if (replacementAttached) scheduleUsbReconnect()
            return
        }

        usbConnectFailures++
        if (usbConnectFailures < USB_CONNECT_MAX_ATTEMPTS) {
            _state.update {
                it.copy(
                    isConnectedToCamera = false,
                    isConnecting = true,
                    usbConnectionError = null
                )
            }
            scheduleUsbReconnect()
            return
        }

        log { "USB_CONNECT paused; waiting for cable reattach" }
        CameraSessionService.stop(getApplication())
        usbRetryPaused = true
        val localized = com.ztransfer.AppLocale.wrap(getApplication())
        _state.update {
            it.copy(
                isConnecting = false,
                usbConnectionError = error.message
                    ?: localized.getString(com.ztransfer.R.string.usb_unknown_error)
            )
        }
        // 线仍物理连接时无法再次获得 attach 事件；暂停并等待实际重新插线，不回退 Wi-Fi。
    }

    private fun scheduleUsbReconnect() {
        viewModelScope.launch {
            delay(RETRY_INTERVAL_MS)
            attachedUsbDevice?.let(::connectUsbDevice)
        }
    }

    private fun onUsbPermissionUnavailable(device: UsbDevice) {
        usbPermissionJob?.cancel()
        usbPermissionJob = null
        if (pendingUsbPermissionDeviceId == device.deviceId) {
            pendingUsbPermissionDeviceId = null
        }
        usbRetryPaused = true
        CameraSessionService.stop(getApplication())
        _state.update {
            it.copy(
                isConnecting = false,
                usbConnectionError = com.ztransfer.AppLocale.wrap(getApplication()).getString(
                    com.ztransfer.R.string.usb_permission_required
                )
            )
        }
    }

    private fun onUsbDeviceDetached(device: UsbDevice) {
        if (_state.value.connectionType == CameraConnectionType.WIFI) return
        val wasPending = pendingUsbPermissionDeviceId == device.deviceId
        val wasAttached = attachedUsbDevice?.deviceId == device.deviceId
        val wasActive = activeUsbDeviceId == device.deviceId
        if (!wasPending && !wasAttached && !wasActive) return

        if (wasPending) {
            usbPermissionJob?.cancel()
            usbPermissionJob = null
            pendingUsbPermissionDeviceId = null
        }
        if (wasAttached) attachedUsbDevice = null
        usbRetryPaused = false
        usbConnectFailures = 0
        _state.update {
            it.copy(
                isConnecting = false,
                usbConnectionError = null
            )
        }
        if (!wasActive) {
            // Also covers a cable removed while USB OpenSession is still in flight.
            return
        }

        activeUsbDeviceId = null
        CameraSessionService.stop(getApplication())
        keepaliveJob?.cancel()
        eventPollJob?.cancel()
        val cam = camera
        camera = null
        _state.update {
            it.copy(
                isConnectedToCamera = false,
                isConnecting = false,
                connectionType = CameraConnectionType.USB
            )
        }
        cleanupScope.launch { cam?.close() }
    }

    private suspend fun reconnectSelectedTransport() {
        when (_state.value.connectionType) {
            CameraConnectionType.USB -> {
                val usb = attachedUsbDevice
                if (usb != null && usbManager.hasPermission(usb)) connectUsbDevice(usb)
            }
            CameraConnectionType.WIFI -> connectToCameraWithRetry()
            null -> {
                val usb = attachedUsbDevice
                if (usb != null && usbManager.hasPermission(usb)) {
                    connectUsbDevice(usb)
                } else {
                    connectToCameraWithRetry()
                }
            }
        }
    }

    // "是否有任务在传输"（含等待中）——后台缩略图填充的开关之一，由 UI 层喂入
    //（TransferViewModel 与本 VM 相互独立，经 MainScreen 桥接）。
    private val transfersBusyFlow = MutableStateFlow(false)
    private val thumbnailPriorityRangeFlow = MutableStateFlow<PhotoDateRange?>(null)

    fun setTransfersBusy(busy: Boolean) {
        transfersBusyFlow.value = busy
    }

    fun setThumbnailPriorityRange(range: PhotoDateRange?) {
        thumbnailPriorityRangeFlow.value = range
    }

    // 遥控页活跃期间同样完全停止填充：监看取帧是连续流量，填充的 GetThumb 会与
    // 参数加载/取帧争抢 ioMutex（表现为进页要等半天、帧率骤降）。与"传输中停止"
    // 同一哲学——前台交互独占通道；退出遥控页自动恢复。
    private val remoteActiveFlow = MutableStateFlow(false)

    private fun isFileScanPaused(): Boolean =
        remoteActiveFlow.value || fhdActiveFlow.value

    fun setRemoteActive(active: Boolean) {
        val wasActive = remoteActiveFlow.value
        remoteActiveFlow.value = active
        if (active) {
            if (fileLoadJob?.isActive == true) {
                log { "FILE_SCAN pause for remote loaded=${_state.value.files.size}" }
            }
            fileLoadJob?.cancel()
        } else if (wasActive && fileLoadPending && _state.value.isConnectedToCamera &&
            !fhdActiveFlow.value
        ) {
            log { "FILE_SCAN resume after remote loaded=${_state.value.files.size}" }
            // 监看期间可能拍摄了新照片，沿用原策略：重新取 handles 后再跳过已发布项。
            loadFiles(preserveExisting = true)
        }
    }

    // FHD 长按预览活跃期间暂停后台缩略图填充：FHD 取图比缩略图慢得多（1-3s vs 100ms），
    // 持续填充的 GetThumb 排队会把 FHD 请求憋在 ioMutex 队列后面、用户感知加载慢。
    // 与 remoteActive 同机制——前台交互独占通道；退出预览自动恢复。
    private val fhdActiveFlow = MutableStateFlow(false)

    // Separate from interactive FHD preview: while this one-shot request runs, the thumbnail
    // sweep yields the PTP channel, but opening/closing the full-screen preview cannot clobber it.
    private val effectPreviewActiveFlow = MutableStateFlow(false)
    private var effectPreviewAttemptKey: String? = null

    fun setFhdActive(active: Boolean) {
        val wasActive = fhdActiveFlow.value
        fhdActiveFlow.value = active
        if (active) {
            if (fileLoadJob?.isActive == true) {
                log { "FILE_SCAN pause for FHD loaded=${_state.value.files.size}" }
            }
            // streamFileInfo 在每条 ObjectInfo 前检查取消；若当前事务已开始，只让这一条收尾。
            fileLoadJob?.cancel()
        } else if (wasActive && fileLoadPending && _state.value.isConnectedToCamera &&
            !remoteActiveFlow.value
        ) {
            val cam = camera
            val snapshot = cam?.let { current ->
                fileScanHandleSnapshot?.takeIf { it.belongsTo(current) }
            }
            if (snapshot != null) {
                log {
                    "FILE_SCAN resume after FHD from handle snapshot " +
                        "loaded=${_state.value.files.size} handles=${snapshot.totalHandleCount}"
                }
                loadFiles(preserveExisting = true, resumeSnapshot = snapshot)
            } else {
                // 预览期间发生重连或暂停发生在 handles 取得之前：旧 handle 不可复用。
                log { "FILE_SCAN resume after FHD with fresh handles" }
                loadFiles()
            }
        }
    }

    init {
        registerUsbReceiver()
        scanAttachedUsbCamera()
        if (_state.value.connectionType != CameraConnectionType.USB) registerNetworkCallback()
        startConnectionWatcher()
        // 磁盘缓存超容淘汰（后台一次，不阻塞启动）。
        viewModelScope.launch(Dispatchers.IO) { pruneThumbDisk() }
        startThumbnailFill()
        startEffectPreviewPrefetch()
    }

    /**
     * 后台缩略图填充：与连接同生共死，【不依赖任何页面】——用户停在队列页/设置里
     * 照常推进。只有两种状态：未传输=按拍摄时间从新到旧全量填充（prefetchThumbnail
     * 只落盘）直到每张都有缓存；传输中=完全停止，通道全部让给传输。
     * 文件列表渐进加载/传输状态翻转都会重启扫描——已落盘的经内存索引微秒级跳过，
     * 重启代价可忽略，进度单调推进。
     */
    private fun startThumbnailFill() {
        viewModelScope.launch {
            combine(
                state.map { it.files }.distinctUntilChanged(),
                transfersBusyFlow,
                remoteActiveFlow,
                fhdActiveFlow,
                effectPreviewActiveFlow,
            ) { files, busy, remote, fhd, effectPreview ->
                Quint(files, busy, remote, fhd, effectPreview)
            }.combine(thumbnailPriorityRangeFlow) { inputs, range -> inputs to range }
                .collectLatest { (inputs, range) ->
                val (files, busy, remote, fhd, effectPreview) = inputs
                if (busy || remote || fhd || effectPreview || files.isEmpty()) return@collectLatest
                // 日期筛选范围优先；范围缓存完后继续全局新→旧，无需额外完成状态。
                val ordered = prioritizedThumbnailFiles(files, range)
                log { "THUMB_SWEEP start n=${ordered.size}" }
                var loaded = 0
                for (file in ordered) {
                    if (!state.value.isConnectedToCamera) {
                        log { "THUMB_SWEEP abort: disconnected, loaded=$loaded" }
                        return@collectLatest
                    }
                    try {
                        if (prefetchThumbnail(file)) loaded++
                    } catch (e: kotlinx.coroutines.CancellationException) {
                        throw e   // 列表更新/传输开始的正常取消，须向上传播
                    } catch (e: Exception) {
                        // 单张异常绝不中断整轮（逃逸异常会悄悄杀死本协程，之后再也不填充）。
                        log { "THUMB_SWEEP item failed handle=${file.handle}: $e" }
                    }
                }
                log { "THUMB_SWEEP done loaded=$loaded/${ordered.size}" }
            }
        }
    }

    /**
     * Once the initial file list has been quiet briefly, fetch exactly one FHD image for the
     * frame/filter settings demos. This is deliberately best-effort: it never blocks file loading,
     * transfers, remote control, or interactive FHD preview, and failures remain invisible.
     * A newly captured latest still replaces the previous demo automatically.
     */
    private fun startEffectPreviewPrefetch() {
        viewModelScope.launch {
            combine(
                state.map { it.files }.distinctUntilChanged(),
                transfersBusyFlow,
                remoteActiveFlow,
                fhdActiveFlow,
            ) { files, busy, remote, fhd -> Quad(files, busy, remote, fhd) }
                .collectLatest { (files, busy, remote, fhd) ->
                    if (busy || remote || fhd || files.isEmpty()) return@collectLatest
                    val latest = latestEffectPreviewFile(files) ?: return@collectLatest
                    val key = effectPreviewKey(latest)
                    if (_state.value.effectPreviewFileKey == key || effectPreviewAttemptKey == key) {
                        return@collectLatest
                    }

                    // File batches and the first visible thumbnails get priority over this demo.
                    delay(EFFECT_PREVIEW_SETTLE_MS)
                    if (transfersBusyFlow.value || remoteActiveFlow.value || fhdActiveFlow.value ||
                        !_state.value.isConnectedToCamera ||
                        effectPreviewKey(latestEffectPreviewFile(_state.value.files) ?: return@collectLatest) != key
                    ) {
                        return@collectLatest
                    }

                    effectPreviewActiveFlow.value = true
                    try {
                        val bitmap = loadFhdBitmap(
                            latest,
                            Bitmap.Config.ARGB_8888,
                            honorExifOrientation = true,
                        )
                        // A real camera response (including unsupported/null) is one completed
                        // attempt. Cancellation by a foreground task is not latched, so idle time
                        // can retry later.
                        effectPreviewAttemptKey = key
                        bitmap ?: return@collectLatest
                        if (_state.value.isConnectedToCamera &&
                            effectPreviewKey(latestEffectPreviewFile(_state.value.files) ?: return@collectLatest) == key
                        ) {
                            _state.update {
                                it.copy(effectPreviewBitmap = bitmap, effectPreviewFileKey = key)
                            }
                            log { "EFFECT_PREVIEW ready handle=${latest.handle} ${bitmap.width}x${bitmap.height}" }
                        }
                    } finally {
                        effectPreviewActiveFlow.value = false
                    }
                }
        }
    }

    private fun effectPreviewKey(file: NikonCamera.FileInfo): String =
        "${file.handle}|${file.fileName}|${file.size}|${file.captureDate.orEmpty()}"

    /**
     * 连接看护：只要未连上相机，就周期性检测手机是否进入候选网段，一旦命中就立即发起连接。
     * 作为系统网络回调的兜底——部分机型回调触发晚或不稳定（DHCP 时序），此循环保证"手机一进
     * 相机 Wi-Fi 就连上"。isNikonWifi() 仅读本地 DHCP 网关，开销极小；网关命中仅表示值得
     * 探测，真正身份仍以 PTP/IP 握手为准，避免把同为 192.168.1.1 的普通路由器当成相机。
     */
    private fun startConnectionWatcher() {
        watcherJob?.cancel()
        watcherJob = viewModelScope.launch {
            while (isActive) {
                if (_state.value.connectionType == CameraConnectionType.USB) {
                    delay(WATCH_INTERVAL_MS)
                    continue
                }
                // dhcpInfo/connectionInfo 是 Binder IPC，放 IO 线程，不在主线程高频抖动。
                val (onNikonWifi, rssi) = withContext(Dispatchers.IO) {
                    val loopback = CameraEndpointOverride.hostOrNull() != null
                    val on = loopback || linkSaysCameraWifi || isNikonWifi()
                    on to (if (on && !loopback) readRssi() else null)
                }
                // 顺带纠正 Wi-Fi 状态与信号强度，避免回调漏报导致 UI 显示滞后。
                if (_state.value.isWifiCandidate != onNikonWifi || _state.value.wifiRssi != rssi) {
                    updateWifiCandidate(onNikonWifi, rssi)
                }
                // 同 onWifiChanged：只负责"在相机 Wi-Fi 上就连上"，绝不主动断开，避免误断打断传输。
                // 购买挂起期间(purchaseHold)不重连:此时是我们自己主动断的，接回去热点就关不掉了。
                if (onNikonWifi && !purchaseHold && !_state.value.isConnectedToCamera && !_state.value.isConnecting) {
                    connectToCameraWithRetry()
                }
                delay(WATCH_INTERVAL_MS)
            }
        }
    }

    private var wifiHeld = false

    private fun registerNetworkCallback() {
        if (_state.value.connectionType == CameraConnectionType.USB) return
        // Debug 内置相机使用进程内回环端点，不依赖 Wi-Fi；Release 实现恒返回 null。
        if (CameraEndpointOverride.hostOrNull() != null) return
        if (wifiHeld) return
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()
        // requestNetwork 而非被动 registerNetworkCallback：向系统声明"本应用需要 Wi-Fi"。
        // 相机热点无互联网，部分厂商系统会把它自动切走/压后；存在活跃请求时系统会保持
        // 连接，且 LinkProperties 等回调推送更及时。个别 ROM 抛异常则退回纯监听。
        try {
            connectivityManager.requestNetwork(request, networkCallback)
        } catch (_: Exception) {
            connectivityManager.registerNetworkCallback(request, networkCallback)
        }
        wifiHeld = true
    }

    private fun releaseWifiNetworkRequest() {
        if (wifiHeld) {
            runCatching { connectivityManager.unregisterNetworkCallback(networkCallback) }
            wifiHeld = false
        }
        wifiNetwork = null
        linkSaysCameraWifi = false
        _state.update {
            it.copy(
                isWifiCandidate = false,
                wifiRssi = null,
                wifiConnectionStatus = WifiConnectionStatus.IDLE
            )
        }
    }

    // 购买挂起:为 true 期间禁止一切自动重连(watcher / onWifiChanged / 重试循环)。
    // 只松开 requestNetwork 不够——心跳仍连着相机,相机不会关热点,手机也切不走;
    // 且 watcher 只要看到还在相机网段就会立刻把刚断开的会话连回去。
    @Volatile private var purchaseHold = false

    /**
     * 购买期间临时断开相机([hold]=false),买完再握回来([hold]=true)。
     *
     * 付款要外网(下单、微信付款都走默认网络),而相机热点没有外网。松手要做三件事,缺一不可:
     * 1. 挂起自动重连(purchaseHold)——否则 watcher 下一拍就把连接接回去;
     * 2. 主动关闭 PTP 会话(发 CloseSession + 关 socket)——相机看到客户端断开才会关掉
     *    自己的 Wi-Fi 热点;光撤 requestNetwork,socket 连着、心跳还在,热点永远不关;
     * 3. 撤销 requestNetwork 占用——系统才会把默认网络从没外网的热点切回蜂窝。
     *    顺序上先发 CloseSession 再撤占用(CloseSession 本身要走相机 Wi-Fi 才送得到)。
     * 买完重新握住:恢复占用、放开重连,watcher/onWifiChanged 沿既有路径自动接管。
     */
    fun holdCameraWifi(hold: Boolean) {
        if (_state.value.connectionType == CameraConnectionType.USB) {
            // USB/PTP does not occupy the phone's default network; keep it connected while paying.
            purchaseHold = false
            return
        }
        purchaseHold = !hold
        if (hold) {
            registerNetworkCallback()
            return
        }
        CameraSessionService.stop(getApplication())
        keepaliveJob?.cancel()
        eventPollJob?.cancel()
        releaseSessionWifiLock()
        val cam = camera
        camera = null
        _state.update {
            it.copy(
                isConnectedToCamera = false,
                isConnecting = false,
                wifiConnectionStatus = WifiConnectionStatus.IDLE
            )
        }
        viewModelScope.launch {
            cam?.close()   // 先发 CloseSession(需相机网络在),再松开对该网络的占用
            // 弹窗若在 close 完成前已关闭(hold 已握回),占用保持不动,避免撤掉刚握回的回调。
            if (purchaseHold && wifiHeld) {
                runCatching { connectivityManager.unregisterNetworkCallback(networkCallback) }
                wifiHeld = false
                // 注销后系统不再推送 onLost,主动清掉链路缓存——否则残留"仍在相机网段"
                // 的旧值,买完握回后重试循环会绑着已死的 Network 空转到用户真正回连为止。
                wifiNetwork = null
                linkSaysCameraWifi = false
            }
        }
    }

    private fun onWifiChanged() {
        if (_state.value.connectionType == CameraConnectionType.USB) return
        viewModelScope.launch {
            val loopback = CameraEndpointOverride.hostOrNull() != null
            val onNikonWifi = loopback || linkSaysCameraWifi || checkNikonWifi()
            val rssi = if (onNikonWifi && !loopback) {
                withContext(Dispatchers.IO) { readRssi() }
            } else {
                null
            }
            updateWifiCandidate(onNikonWifi, rssi)

            // 只在"已在相机 Wi-Fi 但尚未连上相机"时发起连接。
            // 绝不因 isNikonWifi()==false 主动断开：该判断依赖 dhcpInfo 网关，运行中可能瞬时误报，
            // 一旦在传输途中误断会不断打断并重传文件，速度暴跌。真正掉线由下载失败/心跳自然发现。
            // 购买挂起期间(purchaseHold)不重连,理由见 startConnectionWatcher。
            if (onNikonWifi && !purchaseHold && !_state.value.isConnectedToCamera && !_state.value.isConnecting) {
                connectToCameraWithRetry()
            }
        }
    }

    /** Debug 入口主动开启进程内模拟相机；Release 源集返回 false，因此不会改变正式连接流程。 */
    fun connectDebugSimulator() {
        viewModelScope.launch {
            if (_state.value.isConnectedToCamera || _state.value.isConnecting) return@launch
            val enabled = withContext(Dispatchers.IO) {
                CameraEndpointOverride.enableSimulator(getApplication())
            }
            if (!enabled || _state.value.isConnectedToCamera || _state.value.isConnecting) return@launch
            updateWifiCandidate(candidate = true, rssi = null)
            connectToCameraWithRetry()
        }
    }

    /**
     * 更新“疑似相机网络”证据。运行中的真实会话不因 DHCP 的瞬时误报被降级；
     * 未连接时一旦候选特征消失，连接页立即回到无选择的初始状态。
     */
    private fun updateWifiCandidate(candidate: Boolean, rssi: Int?) {
        _state.update { current ->
            val keepConnectionStatus =
                current.isConnectedToCamera &&
                        current.connectionType == CameraConnectionType.WIFI
            current.copy(
                isWifiCandidate = candidate,
                wifiRssi = rssi,
                wifiConnectionStatus = if (!candidate && !keepConnectionStatus) {
                    WifiConnectionStatus.IDLE
                } else {
                    current.wifiConnectionStatus
                }
            )
        }
    }

    /** [isNikonWifi] 的挂起版本：Binder 调用移到 IO 线程执行。 */
    private suspend fun checkNikonWifi(): Boolean = withContext(Dispatchers.IO) { isNikonWifi() }

    /** 读取当前 Wi-Fi 连接的信号强度（dBm）。取不到返回 null。仅在 IO 线程调用。 */
    @Suppress("DEPRECATION")
    private fun readRssi(): Int? {
        return try {
            val rssi = wifiManager.connectionInfo?.rssi ?: return null
            // 未关联/无效时部分机型返回 -127 之类的哨兵值，过滤掉。
            if (rssi == -127 || rssi >= 0) null else rssi
        } catch (_: Exception) {
            null
        }
    }

    @Suppress("DEPRECATION")
    private fun isNikonWifi(): Boolean {
        try {
            val dhcp = wifiManager.dhcpInfo ?: return false
            val gw = dhcp.gateway
            val ip = "${gw and 0xFF}.${(gw shr 8) and 0xFF}.${(gw shr 16) and 0xFF}.${(gw shr 24) and 0xFF}"
            return ip == PtpConstants.CAMERA_IP
        } catch (_: Exception) {
            return false
        }
    }

    /**
     * 持续尝试连接相机：只要还在候选网段就后台重试，直到连上为止。
     * 第一次失败后 UI 结束“识别中”并给出简短原因；重试本身保持静默。
     * 一旦离开候选网段则退出循环，由网络回调在重新连上 Wi-Fi 后再次触发。
     */
    private suspend fun connectToCameraWithRetry() {
        if (purchaseHold || _state.value.connectionType == CameraConnectionType.USB ||
            _state.value.isConnecting || _state.value.isConnectedToCamera
        ) return
        _state.update {
            it.copy(
                isConnecting = true,
                wifiConnectionStatus = if (
                    it.wifiConnectionStatus == WifiConnectionStatus.RECONNECTING
                ) {
                    WifiConnectionStatus.RECONNECTING
                } else {
                    WifiConnectionStatus.PROBING
                }
            )
        }

        // 经 AppLocale.wrap：协议层错误文案（会显示在失败卡片上）与应用内语言一致。
        // 提到循环外：语言变更必经 Activity.recreate()，重试循环存续期间不可能变，
        // 不必每轮重试都重建配置上下文。
        val localizedContext = com.ztransfer.AppLocale.wrap(getApplication())
        // purchaseHold 也随轮检查:重试循环可能在购买挂起前就已在跑,得让它当轮退出。
        var failedAttempts = 0
        while (!purchaseHold && _state.value.connectionType != CameraConnectionType.USB &&
            (CameraEndpointOverride.hostOrNull() != null ||
                linkSaysCameraWifi || checkNikonWifi()) &&
            !_state.value.isConnectedToCamera
        ) {
            val cam = NikonCamera(localizedContext)
            var connected = false
            var failure: Throwable? = null
            val overrideHost = CameraEndpointOverride.hostOrNull()
            cam.connect(
                ip = overrideHost ?: PtpConstants.CAMERA_IP,
                // Debug 内置相机走进程内回环；绑定 Wi-Fi Network 会错误地绕开该端点。
                network = if (overrideHost == null) wifiNetwork else null
            ).fold(
                onSuccess = {
                    // USB 可能在 Wi-Fi 握手期间接入；此时不发布短暂的 Wi-Fi 成功态，
                    // 先释放刚建立的会话，再由循环出口切换到 USB。
                    if (_state.value.connectionType == CameraConnectionType.USB) {
                        cam.close()
                    } else {
                        camera = cam
                        acquireSessionWifiLock()   // 会话保活：连着就不让 Wi-Fi 打盹
                        _state.update {
                            it.copy(
                                isConnectedToCamera = true,
                                isConnecting = false,
                                connectionType = CameraConnectionType.WIFI,
                                wifiConnectionStatus = WifiConnectionStatus.IDLE
                            )
                        }
                        CameraSessionService.start(getApplication())
                        startKeepalive()
                        loadFiles()
                        startEventPolling()
                        connected = true
                    }
                },
                onFailure = { error ->
                    failure = error
                    cam.close()
                }
            )
            if (connected) {
                // 握手期间购买挂起被置起(connect 要几秒,窗口真实存在):
                // 立即拆掉刚建立的会话,不给相机热点续命。
                if (purchaseHold) holdCameraWifi(false)
                return
            }

            // 一次真实握手失败后结束可见的“识别中”，但保留原有后台自动重试。
            // 候选网络可能只是使用 192.168.1.1 的普通路由器，绝不能继续呈现成功场景。
            val stillCandidate = CameraEndpointOverride.hostOrNull() != null ||
                linkSaysCameraWifi || checkNikonWifi()
            if (!stillCandidate) break
            failure?.let { error ->
                failedAttempts++
                _state.update { current ->
                    if (current.wifiConnectionStatus == WifiConnectionStatus.RECONNECTING) {
                        current
                    } else {
                        current.copy(wifiConnectionStatus = classifyWifiConnectionFailure(error))
                    }
                }
            }
            val retryDelay = if (
                _state.value.wifiConnectionStatus == WifiConnectionStatus.RECONNECTING ||
                failedAttempts <= 1
            ) {
                RETRY_INTERVAL_MS
            } else {
                WIFI_BACKGROUND_RETRY_INTERVAL_MS
            }
            delay(retryDelay)
        }

        // 已离开相机 Wi-Fi（或已连上）；清除“连接中”状态，等待下次网络变化再触发。
        _state.update {
            it.copy(
                isConnecting = false,
                wifiConnectionStatus = if (
                    it.isConnectedToCamera ||
                    it.isWifiCandidate
                ) {
                    it.wifiConnectionStatus
                } else {
                    WifiConnectionStatus.IDLE
                }
            )
        }
        if (camera == null) CameraSessionService.stop(getApplication())
        if (_state.value.connectionType == CameraConnectionType.USB) {
            attachedUsbDevice?.let(::connectUsbDevice)
        }
    }

    /**
     * 周期性心跳：空闲时每 [KEEPALIVE_INTERVAL_MS] 探测一次相机，及时发现掉线并更新状态。
     * keepalive() 与普通命令互斥；若协议下载正在进行（包括分块之间的短暂空窗），本轮
     * 直接视为连接活跃并跳过主动命令。下载数据本身已证明连接有效，不能再让心跳插队。
     */
    private fun startKeepalive() {
        keepaliveJob?.cancel()
        keepaliveJob = viewModelScope.launch {
            while (isActive) {
                delay(KEEPALIVE_INTERVAL_MS)
                val cam = camera ?: break
                if (!cam.keepalive()) {
                    camera = null
                    if (cam.connectionType == CameraConnectionType.WIFI) releaseSessionWifiLock()
                    cam.close()
                    // 掉线不报错，直接进入重连（新协程，避免与当前心跳协程的取消纠缠）。
                    // 不清空文件列表：网格保留（缩略图走缓存），断开状态由顶栏信号按钮
                    // 承担（红色断连图标），点击缩略图有抖动+提示反馈；重连后 loadFiles
                    // 整表刷新，不存在陈旧 handle 被使用的问题（点击已被连接检查挡住）。
                    _state.update {
                        it.copy(
                            isConnectedToCamera = false,
                            wifiConnectionStatus = if (
                                cam.connectionType == CameraConnectionType.WIFI
                            ) {
                                WifiConnectionStatus.RECONNECTING
                            } else {
                                it.wifiConnectionStatus
                            }
                        )
                    }
                    viewModelScope.launch { reconnectSelectedTransport() }
                    break
                }
            }
        }
    }

    /**
     * 事件轮询(照片列表实时新增):连接空闲时每 [EVENT_POLL_INTERVAL_MS] 拉一次相机
     * 事件,收到 ObjectAdded(机身快门产生的新照片)即经 [onCameraObjectAdded] 插入
     * 列表顶部——用户在照片列表页(或回到列表)就能看到新拍的照片,无需整表刷新。
     * 通道纪律(与缩略图填充同哲学,绝不打扰前台交互):
     * - 传输中完全停:不碰传输热路径;事件在相机侧排队,传完下一轮一次性补上;
     * - 遥控页打开时完全停:GetEvent 取走即消费,监看页的事件循环是彼时唯一消费者
     *   (拍摄确认依赖 ObjectAdded,被这里抢走会破坏快门流程),它会代为转交;
     * - FHD 预览/初始列表加载期间同样让路。
     * 不支持 0x90C7 的机型 rcPollEvents 恒返回空列表,循环退化为偶发一条被拒绝的
     * 小命令,无副作用。掉线后 camera 置空,循环自然退出;重连时重启。
     */
    private fun startEventPolling() {
        eventPollJob?.cancel()
        eventPollJob = viewModelScope.launch {
            while (isActive) {
                delay(EVENT_POLL_INTERVAL_MS)
                val cam = camera ?: break
                if (!_state.value.isConnectedToCamera) break
                if (_state.value.isLoadingFiles) continue
                if (transfersBusyFlow.value || remoteActiveFlow.value || fhdActiveFlow.value) continue
                val events = runCatching { cam.rcPollEvents() }.getOrDefault(emptyList())
                for (e in events) {
                    if (e.first == Lab.EVT_OBJECT_ADDED) onCameraObjectAdded(e.second.toInt())
                }
            }
        }
    }

    /**
     * 相机新增对象(机身快门/遥控拍摄):取该 handle 的对象信息,插到列表顶部。
     * handle 降序 ≈ 拍摄从新到旧,新对象 handle 最大,前插即保持既有顺序;日期分组、
     * 类型筛选都由 UI 层从 files 派生,新照片自动归入当天分组。与 loadFiles 同键
     * 去重(双卡备份模式同一张照片两个 handle,只显示一份)。
     * 遥控页打开时由其事件循环转交调用;平时由 [startEventPolling] 驱动。
     */
    fun onCameraObjectAdded(handle: Int) {
        val cam = camera ?: return
        if (_state.value.files.any { it.handle == handle }) return
        viewModelScope.launch {
            val info = runCatching {
                var got: NikonCamera.FileInfo? = null
                cam.streamFileInfo(listOf(handle), batchSize = 1) { batch, _, _ ->
                    got = batch.firstOrNull()
                }
                got
            }.getOrNull() ?: return@launch
            _state.update { s ->
                val duplicateIndex = s.files.indexOfFirst {
                    it.handle == handle ||
                        it.logicalIdentity() == info.logicalIdentity()
                }
                if (duplicateIndex < 0) {
                    s.copy(files = listOf(info) + s.files)
                } else {
                    val existing = s.files[duplicateIndex]
                    val merged = mergeStorageMembership(existing, info)
                    if (merged === existing) s else s.copy(
                        files = s.files.toMutableList().apply { this[duplicateIndex] = merged }
                    )
                }
            }
        }
    }

    private fun loadFiles(
        preserveExisting: Boolean = false,
        resumeSnapshot: FileScanHandleSnapshot? = null,
    ) {
        val cam = camera ?: return
        val generation = ++fileLoadGeneration
        fileLoadJob?.cancel()
        fileLoadPending = true
        // 没有显式传入同会话恢复快照，就代表本轮要重新读取 handles；旧快照不能在
        // 新一轮枚举尚未完成时被后续暂停误复用。
        if (resumeSnapshot == null) fileScanHandleSnapshot = null
        if (!preserveExisting) {
            thumbnailCache.evictAll()   // 新会话/新列表，旧缩略图作废
            noThumbHandles.clear()      // handle 跨会话可能复用，负缓存一并作废
            effectPreviewAttemptKey = null
        }
        _state.update {
            it.copy(
                isLoadingFiles = !isFileScanPaused(),
                hasCompletedFileScan = false,
                files = if (preserveExisting) it.files else emptyList(),
                storageIds = if (preserveExisting) it.storageIds else emptyList(),
                effectPreviewBitmap = if (preserveExisting) it.effectPreviewBitmap else null,
                effectPreviewFileKey = if (preserveExisting) it.effectPreviewFileKey else null,
            )
        }
        // 监看和交互式大图都先于列表枚举：保留待加载标记，不向 ioMutex 排队。
        if (isFileScanPaused()) return

        if (FileOrderProbe.enabled) {
            if (resumeSnapshot == null) {
                FileOrderProbe.beginScan(
                    "fresh preserveExisting=$preserveExisting existing=${_state.value.files.size}"
                )
            } else {
                FileOrderProbe.addNote(
                    "resume existing handle snapshot; loaded=${_state.value.files.size}"
                )
            }
        }

        log {
            "FILE_SCAN start preserve=$preserveExisting snapshot=${resumeSnapshot != null} " +
                "existing=${_state.value.files.size}"
        }
        val job = viewModelScope.launch(start = kotlinx.coroutines.CoroutineStart.LAZY) {
            try {
                val existingFiles =
                    if (preserveExisting && camera === cam) _state.value.files else emptyList()
                val existingHandles = existingFiles.asSequence().map { it.handle }.toHashSet()
                val reusableSnapshot = resumeSnapshot?.takeIf { it.belongsTo(cam) }
                val storageIds: List<Int>
                val remainingHandleOrders: List<StorageHandleOrder>
                val activeSnapshot: FileScanHandleSnapshot
                if (reusableSnapshot != null) {
                    // 大图预览只是同会话短暂停顿：StorageID/handles 已在开局取得，直接继续。
                    storageIds = reusableSnapshot.storageIds
                    remainingHandleOrders = reusableSnapshot.remainingAfter(existingHandles)
                    activeSnapshot = reusableSnapshot
                } else {
                    // 双卡机型（Z5 II / Z6 III 等）：枚举【所有】存储卡的对象并合并，单卡机型
                    // 行为不变。PTP StorageID 低 16 位为逻辑存储号，0 表示卡槽无卡，跳过。
                    storageIds = cam.getStorageIds()
                        .filter { it and 0xFFFF != 0 }
                        .distinct()
                        .sorted()
                    if (fileLoadGeneration != generation || camera !== cam) return@launch
                    if (FileOrderProbe.enabled) FileOrderProbe.recordStorageIds(storageIds)
                    _state.update { it.copy(storageIds = storageIds) }
                    if (storageIds.isEmpty()) {
                        fileScanHandleSnapshot = null
                        fileLoadPending = false
                        _state.update { it.copy(isLoadingFiles = false, hasCompletedFileScan = true) }
                        if (FileOrderProbe.enabled) {
                            FileOrderProbe.finishScan("complete: no usable storage")
                        }
                        return@launch
                    }

                    val rawHandlesByStorage = storageIds.map { storageId ->
                        val startedAtMs = if (FileOrderProbe.enabled) {
                            SystemClock.elapsedRealtime()
                        } else {
                            0L
                        }
                        val rawHandles = cam.getObjectHandles(storageId)
                        if (FileOrderProbe.enabled) {
                            FileOrderProbe.recordRawHandles(
                                storageId = storageId,
                                handles = rawHandles,
                                elapsedMs = SystemClock.elapsedRealtime() - startedAtMs,
                            )
                        }
                        storageId to rawHandles
                    }
                    val handleOrders = newestFirstHandleOrders(rawHandlesByStorage)
                    if (fileLoadGeneration != generation || camera !== cam) return@launch
                    if (handleOrders.all { it.newestFirstHandles.isEmpty() }) {
                        fileScanHandleSnapshot = null
                        fileLoadPending = false
                        _state.update { it.copy(isLoadingFiles = false, hasCompletedFileScan = true) }
                        if (FileOrderProbe.enabled) FileOrderProbe.finishScan("complete: no handles")
                        return@launch
                    }

                    // 每张卡只反转相机的自然顺序。单卡可直接流式读取；双卡稍后用每卡
                    // 当前 head 的真实拍摄时间归并，不能把不透明 handle 做全局数值排序。
                    activeSnapshot = FileScanHandleSnapshot(
                        sessionToken = cam,
                        storageIds = storageIds,
                        handleOrders = handleOrders,
                    )
                    fileScanHandleSnapshot = activeSnapshot
                    if (FileOrderProbe.enabled) {
                        val nonEmptyOrders = handleOrders.filter {
                            it.newestFirstHandles.isNotEmpty()
                        }
                        if (nonEmptyOrders.size == 1) {
                            FileOrderProbe.recordScheduledHandles(
                                nonEmptyOrders.single().newestFirstHandles
                            )
                        } else {
                            FileOrderProbe.recordScheduledHandles(emptyList())
                            FileOrderProbe.addNote(
                                "dual-card schedule is resolved incrementally by captureDate"
                            )
                        }
                    }
                    remainingHandleOrders = activeSnapshot.remainingAfter(existingHandles)
                }

                if (fileLoadGeneration != generation || camera !== cam) return@launch
                _state.update { it.copy(storageIds = storageIds) }
                val nonEmptyRemainingOrders = remainingHandleOrders.filter {
                    it.newestFirstHandles.isNotEmpty()
                }
                val remainingHandleCount = nonEmptyRemainingOrders.sumOf {
                    it.newestFirstHandles.size
                }
                if (remainingHandleCount == 0) {
                    if (fileScanHandleSnapshot === activeSnapshot) fileScanHandleSnapshot = null
                    fileLoadPending = false
                    _state.update { it.copy(isLoadingFiles = false, hasCompletedFileScan = true) }
                    if (FileOrderProbe.enabled) {
                        FileOrderProbe.finishScan("complete: nothing remaining")
                    }
                    return@launch
                }

                val allFiles = existingFiles.toMutableList()
                // 备份模式下同一张照片在两张卡各有一份（handle 不同）：按 名称+大小+拍摄时间
                // 去重，列表只显示一份；溢出/RAW+JPG 分卡等模式互不相同，不受影响。
                val indexByIdentity = HashMap<String, Int>(
                    existingFiles.size + remainingHandleCount
                )
                existingFiles.forEachIndexed { index, file ->
                    indexByIdentity[file.logicalIdentity()] = index
                }

                val dynamicDualCardSchedule = activeSnapshot.handleOrders.count {
                    it.newestFirstHandles.isNotEmpty()
                } > 1
                val publishBatch: suspend (List<NikonCamera.FileInfo>, Int, Int) -> Unit =
                    { batch, loaded, total ->
                    activeSnapshot.markProcessed(batch.map { it.handle })
                    if (FileOrderProbe.enabled && dynamicDualCardSchedule) {
                        FileOrderProbe.appendScheduledHandles(batch.map { it.handle })
                    }
                    batch.forEach { file ->
                        val identity = file.logicalIdentity()
                        val existingIndex = indexByIdentity[identity]
                        if (existingIndex == null) {
                            indexByIdentity[identity] = allFiles.size
                            allFiles += file
                        } else {
                            allFiles[existingIndex] = mergeStorageMembership(
                                allFiles[existingIndex],
                                file,
                            )
                        }
                    }
                    val snapshot = allFiles.toList()
                    // onBatch 回调运行在 IO 线程，用 update 原子读改写避免与主线程写入竞争。
                    if (fileLoadGeneration == generation && camera === cam) {
                        _state.update { it.copy(files = snapshot, isLoadingFiles = loaded < total) }
                    }
                }
                if (nonEmptyRemainingOrders.size == 1) {
                    cam.streamFileInfo(
                        handles = nonEmptyRemainingOrders.single().newestFirstHandles,
                        batchSize = 20,
                        onBatch = publishBatch,
                    )
                } else {
                    cam.streamMergedFileInfo(
                        newestFirstHandlesByStorage = nonEmptyRemainingOrders.map {
                            it.newestFirstHandles
                        },
                        batchSize = 20,
                        onBatch = publishBatch,
                    )
                }

                if (fileLoadGeneration != generation || camera !== cam) return@launch
                if (fileScanHandleSnapshot === activeSnapshot) fileScanHandleSnapshot = null
                fileLoadPending = false
                log { "FILE_SCAN done files=${allFiles.size}" }
                _state.update { it.copy(isLoadingFiles = false, hasCompletedFileScan = true) }
                if (FileOrderProbe.enabled) {
                    FileOrderProbe.finishScan("complete: files=${allFiles.size}")
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                // 进入监看/大图的正常抢占：保留已加载部分与 pending。大图同会话复用 handles；
                // 监看退出仍重新获取 handles，以包含监看期间新增的照片。
                if (FileOrderProbe.enabled) FileOrderProbe.finishScan("paused/cancelled")
                throw e
            } catch (e: Exception) {
                // 扫描中断（掉线/读超时）：保留已加载的部分，掉线由心跳发现并触发重连。
                if (fileLoadGeneration == generation && camera === cam) {
                    fileScanHandleSnapshot = null
                    fileLoadPending = false
                    _state.update { it.copy(isLoadingFiles = false) }
                }
                if (FileOrderProbe.enabled) {
                    FileOrderProbe.finishScan(
                        "failed: ${e.javaClass.simpleName}: ${e.message.orEmpty()}"
                    )
                }
            } finally {
                // 新会话可能已启动了下一轮加载；旧任务的迟到 finally 不得把新任务的
                // loading 状态清掉。
                if (fileLoadJob === coroutineContext[Job]) {
                    fileLoadJob = null
                    _state.update { it.copy(isLoadingFiles = false) }
                }
            }
        }
        fileLoadJob = job
        job.start()
    }

    fun getCamera(): NikonCamera? = camera

    /**
     * 前台交互已确认命令通道不可再复用（例如读到半包时超时）。
     * 只接受当前实例的报告，避免旧会话的迟到异常拆掉已经重连好的新会话。
     */
    fun onCameraTransportLost(failedCamera: NikonCamera) {
        if (camera !== failedCamera) return
        camera = null
        keepaliveJob?.cancel()
        eventPollJob?.cancel()
        if (failedCamera.connectionType == CameraConnectionType.WIFI) releaseSessionWifiLock()
        _state.update {
            it.copy(
                isConnectedToCamera = false,
                isConnecting = false,
                wifiConnectionStatus = if (
                    failedCamera.connectionType == CameraConnectionType.WIFI
                ) {
                    WifiConnectionStatus.RECONNECTING
                } else {
                    it.wifiConnectionStatus
                }
            )
        }
        viewModelScope.launch {
            failedCamera.close()
            reconnectSelectedTransport()
        }
    }

    /** 内存缓存的同步只读引用（未缓存返回 null,绝不发起取图）。仅主线程,与缓存同约束。 */
    fun cachedThumbnail(handle: Int): ImageBitmap? = thumbnailCache.get(handle)

    /**
     * 加载指定文件的缩略图（用于可见格子/预览/队列小图）。三级查找：
     * 内存 LRU → 磁盘缓存（毫秒级解码）→ 相机 GetThumb（取到即落盘 + 入内存）。
     * 确认无缩略图的负缓存直接返回 null。同 handle 的并发请求共享同一次取图。
     * 磁盘键是"文件名+大小+拍摄时间"的稳定身份，与会话级 handle 无关——断线重连
     * 后不必重新向相机拉图。相机未连接时磁盘命中仍可显示。
     * [allowRemote] 为 false 时只走内存/磁盘路径；用于大图打开期间暂停底层网格的
     * GetThumb，关闭后调用方以 true 重试即可恢复。
     *
     * 传输进行中也允许请求：大小已知且支持分块的普通文件每 2MB、超过 512MB 的文件
     * 每 32MB 释放一次相机通道，缩略图可在块间穿插；兼容整传路径仍需等待当前文件完成。
     */
    suspend fun loadThumbnail(
        file: NikonCamera.FileInfo,
        allowRemote: Boolean = true,
    ): ImageBitmap? {
        val handle = file.handle
        thumbnailCache.get(handle)?.let { return it }
        if (handle in noThumbHandles) return null
        // 大图预览期间，底层照片网格仍可读取手机上的磁盘缓存，但不能再向相机发
        // GetThumb。关闭大图后调用方会用 allowRemote=true 重新进入；当前大图仅在
        // FHD 不可用时显式放开远程缩略图作为兜底。
        loadThumbnailFromDisk(file)?.let { return it }
        if (!allowRemote) return null
        // 后台可能先一步开始同一 handle 的落盘请求；等它结束后直接从磁盘解码，
        // 不在 remoteThumbGate 后面再排一条重复 GetThumb。
        inflightPrefetches[handle]?.let { prefetch ->
            try {
                prefetch.await()
            } catch (e: kotlinx.coroutines.CancellationException) {
                // 自己被取消（格子滚出屏幕）要传播；若只是旧后台顺序被日期/列表更新取消，
                // 当前可见格仍应接手正常加载。
                if (!currentCoroutineContext().isActive) throw e
            } catch (_: Exception) {
                // 瞬时失败不负缓存，继续走正常可见格加载路径重试。
            }
            thumbnailCache.get(handle)?.let { return it }
            if (handle in noThumbHandles) return null
            loadThumbnailFromDisk(file)?.let { return it }
        }
        // 复用进行中的请求（跳过已被取消但尚未从表中清理的条目）。
        val entry = inflightThumbs[handle]?.takeIf { !it.deferred.isCancelled }
            ?: InflightThumb(viewModelScope.async { fetchAndDecodeThumb(file) })
                .also { inflightThumbs[handle] = it }
        entry.waiters++
        try {
            return entry.deferred.await()   // 调用方被取消时在此抛出并传播，不能吞掉
        } finally {
            entry.waiters--
            if (entry.waiters == 0) {
                // 最后一个等待者离开：请求仍未完成说明所有调用方都已取消（滚出屏幕），
                // 连带取消底层请求，别让排队的 GetThumb 挤占后续可见格子的加载。
                if (!entry.deferred.isCompleted) entry.deferred.cancel()
                if (inflightThumbs[handle] === entry) inflightThumbs.remove(handle)
            }
        }
    }

    /**
     * 后台填充专用：确保缩略图字节已在【磁盘】缓存——不解码、不写内存 LRU。
     * 返回 true 表示已可用（内存/磁盘/确认无图）。
     *
     * 为什么不复用 [loadThumbnail]：内存 LRU 只装得下几百张解码位图，全量扫描若逐张
     * 解码入内存，扫到后面会把前面（以及视口附近）的全部挤出去——扫描白跑，还破坏
     * 可见区缓存。落盘不占堆内存，几千张也只有几十 MB；格子滚到时从磁盘毫秒级解码。
     */
    suspend fun prefetchThumbnail(file: NikonCamera.FileInfo): Boolean {
        val handle = file.handle
        if (handle in noThumbHandles) return true
        if (thumbnailCache.get(handle) != null) return true
        val disk = diskFile(file)
        if (disk.name in diskIndexSet()) return true
        // 可见格子正在取同一张：共乘同一次请求（结果会自动落盘）。作为共同等待者，
        // 即使格子滚出屏幕取消了自己的等待，本次共乘也会把请求保活到完成——
        // 用户来回翻动导致的"格子请求发出又取消"绝不会让这张图两头落空。
        if (inflightThumbs[handle]?.deferred?.isCancelled == false) {
            return loadThumbnail(file) != null
        }
        inflightPrefetches[handle]?.let { return it.await() }
        val completion = CompletableDeferred<Boolean>()
        inflightPrefetches[handle] = completion
        return try {
            val result = fetchThumbnailToDisk(handle, disk)
            completion.complete(result)
            result
        } catch (e: Throwable) {
            completion.completeExceptionally(e)
            throw e
        } finally {
            if (inflightPrefetches[handle] === completion) inflightPrefetches.remove(handle)
        }
    }

    private suspend fun fetchThumbnailToDisk(
        handle: Int,
        disk: File,
    ): Boolean {
        val cam = camera ?: return false
        val bytes = remoteThumbGate.withPermit {
            if (FileOrderProbe.enabled) {
                getRemoteThumbnailProbed(cam, handle, "background")
            } else {
                cam.getThumbnail(handle)
            }
        }   // 瞬时失败会抛出，由扫描循环按单张失败处理
        if (bytes == null || bytes.isEmpty()) {
            noThumbHandles.add(handle)
            return true
        }
        withContext(Dispatchers.IO) { writeAtomic(disk, bytes) }
        diskIndex?.add(disk.name)
        return true
    }

    /** 仅包裹现有 GetThumb 事务记录实际进相机通道的顺序；Debug 不增加任何相机请求。 */
    private suspend fun getRemoteThumbnailProbed(
        cam: NikonCamera,
        handle: Int,
        lane: String,
    ): ByteArray? {
        val sequence = if (FileOrderProbe.enabled) {
            FileOrderProbe.beginThumbnail(handle, lane)
        } else {
            -1
        }
        return try {
            val bytes = cam.getThumbnail(handle)
            if (FileOrderProbe.enabled) {
                FileOrderProbe.finishThumbnail(
                    sequence = sequence,
                    outcome = if (bytes == null || bytes.isEmpty()) "no-thumbnail" else "ok",
                    byteCount = bytes?.size,
                )
            }
            bytes
        } catch (e: kotlinx.coroutines.CancellationException) {
            if (FileOrderProbe.enabled) {
                FileOrderProbe.finishThumbnail(sequence, "cancelled", null)
            }
            throw e
        } catch (e: Exception) {
            if (FileOrderProbe.enabled) {
                FileOrderProbe.finishThumbnail(
                    sequence,
                    "error:${e.javaClass.simpleName}",
                    null,
                )
            }
            throw e
        }
    }

    /**
     * 裁掉缩略图里烘焙的黑边：相机把 3:2（照片）/16:9（视频）画面塞进 4:3 缩略图，
     * 上下（竖构图时罕见地左右）带黑条。从四边向内逐行/列扫描，一条线上 ≥97% 采样点
     * 近黑即算黑边；黑边必须两侧成对且近似对称（letterbox 的特征），否则视为画面自身的
     * 暗部，不裁。扫描越过 [BAR_MAX_FRACTION] 上限（整图偏暗，如夜景）也不裁。
     * 检出后每侧多裁 1px，吃掉 JPEG 在黑边交界处的灰色过渡线，边缘干净"刚刚好"。
     * 仅在解码时执行一次（后台线程），结果入缓存，滚动与传输热路径零开销。
     */
    private fun cropLetterbox(src: Bitmap): Bitmap {
        val w = src.width
        val h = src.height
        if (w < 16 || h < 16) return src
        val buf = IntArray(maxOf(w, h))

        // 横线（y 行）或竖线（x 列）是否几乎全为近黑像素。隔点采样，量级仅几千次整数比较。
        fun lineIsBlack(index: Int, horizontal: Boolean): Boolean {
            val n = if (horizontal) w else h
            if (horizontal) src.getPixels(buf, 0, w, 0, index, w, 1)
            else src.getPixels(buf, 0, 1, index, 0, 1, h)
            var dark = 0
            var total = 0
            var i = 0
            while (i < n) {
                val p = buf[i]
                if ((p ushr 16 and 0xFF) < BAR_BLACK_MAX &&
                    (p ushr 8 and 0xFF) < BAR_BLACK_MAX &&
                    (p and 0xFF) < BAR_BLACK_MAX
                ) dark++
                total++
                i += 2
            }
            return dark * 100 >= total * 97
        }

        // 从两端向内数黑线；不成对/不对称/越过上限均按"无黑边"处理，成对时各 +1px 裁掉过渡线。
        fun scanPair(size: Int, isBlack: (Int) -> Boolean): Pair<Int, Int> {
            val limit = (size * BAR_MAX_FRACTION).toInt()
            var a = 0
            while (a < limit && isBlack(a)) a++
            var b = 0
            while (b < limit && isBlack(size - 1 - b)) b++
            return if (a == 0 || b == 0 || a >= limit || b >= limit || kotlin.math.abs(a - b) > 3) 0 to 0
            else a + 1 to b + 1
        }

        val (top, bottom) = scanPair(h) { y -> lineIsBlack(y, horizontal = true) }
        val (left, right) = scanPair(w) { x -> lineIsBlack(x, horizontal = false) }
        if (top == 0 && left == 0) return src
        return Bitmap.createBitmap(src, left, top, w - left - right, h - top - bottom)
    }

    /**
     * 视频封面黑边兜底：[cropLetterbox] 的逐行严判（97% 近黑、两侧对称、15% 上限）对视频
     * 缩略图容易失手——16:9 塞 4:3 的黑边本就贴着 12.5%/侧的上限，画面暗部与黑边粘连或
     * 噪声稍大就整体放弃。视频画面固定 16:9：若裁后仍明显高于 16:9，量一下"裁到 16:9 会
     * 去掉的上下带"的**平均亮度**，确实近黑才居中裁掉——刚好裁到内容边缘，不多裁（多裁
     * 内容放大就糊）。均值判据比逐行判据宽容（几个噪点拉不动均值），又不会误裁真实暗景
     * （画面均值远高于黑条）。每侧多裁 1px 吃掉交界灰线，与 [cropLetterbox] 同规。
     */
    private fun cropVideoBars(src: Bitmap): Bitmap {
        val w = src.width
        val h = src.height
        if (w < 16 || h < 16) return src
        val cut = (h - w * 9 / 16) / 2
        if (cut < 2 || h - (cut + 1) * 2 < 8) return src   // 已接近 16:9 或图太小，无带可裁
        val buf = IntArray(w)
        fun bandIsDark(y0: Int, y1: Int): Boolean {
            var sum = 0L
            var cnt = 0
            var y = y0
            while (y < y1) {
                src.getPixels(buf, 0, w, 0, y, w, 1)
                var x = 0
                while (x < w) {
                    val p = buf[x]
                    sum += maxOf(p ushr 16 and 0xFF, p ushr 8 and 0xFF, p and 0xFF)
                    cnt++
                    x += 2
                }
                y += 2
            }
            return cnt > 0 && sum < cnt.toLong() * BAR_AVG_MAX
        }
        if (!bandIsDark(0, cut) || !bandIsDark(h - cut, h)) return src
        return Bitmap.createBitmap(src, 0, cut + 1, w, h - (cut + 1) * 2)
    }

    private suspend fun loadThumbnailFromDisk(file: NikonCamera.FileInfo): ImageBitmap? {
        val disk = diskFile(file)
        return try {
            val bytes = withContext(Dispatchers.IO) {
                if (disk.isFile) try { disk.readBytes() } catch (_: Exception) { null } else null
            }
            if (bytes == null || bytes.isEmpty()) return null
            decodeThumbnail(file, bytes, disk, fromDisk = true)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            // 本地坏缓存不能让格子的加载协程失败；删掉后，允许远程的调用会正常重取。
            withContext(Dispatchers.IO) { disk.delete() }
            diskIndex?.remove(disk.name)
            log { "THUMB disk decode failed handle=${file.handle}: ${e.javaClass.simpleName}" }
            null
        }
    }

    private suspend fun fetchAndDecodeThumb(file: NikonCamera.FileInfo): ImageBitmap? {
        val handle = file.handle
        return try {
            // 创建共享远程请求前已经查过一次磁盘；排队期间后台可能刚好写入，再查一次
            // 可避免一条重复的 GetThumb。
            loadThumbnailFromDisk(file)?.let { return it }
            val disk = diskFile(file)
            val bytes = remoteThumbGate.withPermit {
                val cam = camera ?: return@withPermit null
                if (FileOrderProbe.enabled) {
                    getRemoteThumbnailProbed(cam, handle, "visible")
                } else {
                    cam.getThumbnail(handle)
                }
            }
            if (bytes == null || bytes.isEmpty()) {
                noThumbHandles.add(handle)   // 相机明确表示无缩略图：负缓存，不再重试
                log { "THUMB no-thumb handle=$handle (resp non-OK / empty)" }
                return null
            }
            withContext(Dispatchers.IO) { writeAtomic(disk, bytes) }
            diskIndex?.add(disk.name)
            decodeThumbnail(file, bytes, disk, fromDisk = false)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            // IO 瞬时失败（掉线等）：不负缓存，重连后仍可加载
            log { "THUMB fetch failed handle=$handle: ${e.javaClass.simpleName}: ${e.message}" }
            null
        }
    }

    private suspend fun decodeThumbnail(
        file: NikonCamera.FileInfo,
        data: ByteArray,
        disk: File,
        fromDisk: Boolean,
    ): ImageBitmap? {
        val image = withContext(Dispatchers.Default) {
            // 解码后立即精确裁掉烘焙在缩略图里的黑边（3:2/16:9 塞 4:3 的上下黑条），
            // 裁好的位图进缓存——列表格子/队列小图/预览全都拿到无黑边的图，
            // UI 层不再需要"放大遮边"的近似 hack。
            BitmapFactory.decodeByteArray(data, 0, data.size)
                ?.let { cropLetterbox(it) }
                ?.let { if (file.extension in VIDEO_EXTENSIONS) cropVideoBars(it) else it }
                ?.asImageBitmap()
        }
        if (image == null) {
            // 解码失败：删掉磁盘上的坏文件。磁盘来源不负缓存（下次直接找相机重取）；
            // 相机新鲜字节都解不了才视为确认无图。
            withContext(Dispatchers.IO) { disk.delete() }
            diskIndex?.remove(disk.name)
            if (!fromDisk) noThumbHandles.add(file.handle)
            log {
                "THUMB decode failed handle=${file.handle} bytes=${data.size} fromDisk=$fromDisk"
            }
            return null
        }
        thumbnailCache.put(file.handle, image)
        return image
    }

    /**
     * 长按预览专用：加载 FHD (1920×1080) 预览图。直接从相机拉 FHD JPEG 并解码。
     * 任何环节失败均返回 null，调用方静默回退到缩略图。
     *
     * 大图打开后，底层网格会改为仅查本地缓存，并取消自己尚未完成的远程等待；大图页
     * 也先走本地缩略图，只有 FHD 确认不可用且 EXIF 已完成时才远程取一张兜底。因此这里
     * 不需要全局清理 inflightThumbs，避免误伤仍有合法等待者的共享请求。
     *
     * 不复用设置页的效果演示图：该图会按 EXIF 校正方向，而全屏预览保留相机返回
     * 的像素方向，继续由既有手动旋转功能负责。
     * 调用方应先通过 [setFhdActive] 暂停后台缩略图填充，再调用本方法。
     */
    suspend fun loadFhdPreview(file: NikonCamera.FileInfo): ImageBitmap? {
        return loadFhdBitmap(
            file,
            Bitmap.Config.RGB_565,
            honorExifOrientation = false,
        )?.asImageBitmap()
    }

    /** 当前照片的 FHD 与 EXIF 共用一次优先窗口，避免传输块插入两者之间。 */
    suspend fun <T> withInteractivePreviewPriority(block: suspend () -> T): T {
        val cam = camera
        return if (cam != null) cam.withInteractivePreviewPriority(block) else block()
    }

    private suspend fun loadFhdBitmap(
        file: NikonCamera.FileInfo,
        config: Bitmap.Config,
        honorExifOrientation: Boolean,
    ): Bitmap? {
        val cam = camera ?: return null
        val startedAt = android.os.SystemClock.elapsedRealtime()
        val bytes = try {
            cam.getFhdPicture(file.handle)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        } ?: run {
            log { "FHD failed handle=${file.handle} total=${android.os.SystemClock.elapsedRealtime() - startedAt}ms" }
            return null
        }
        val receivedAt = android.os.SystemClock.elapsedRealtime()

        return withContext(Dispatchers.Default) {
            try {
                // FHD 预览图是相机直出的 1920×1080 JPEG，非缩略图，不做黑边裁切。
                // 交互式长按使用 RGB_565 控制内存；设置演示图使用 ARGB_8888，确保连续
                // 调色计算不会先被 565 量化。两者共用同一条可靠的取图/解码路径。
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                var sampleSize = 1
                while (maxOf(bounds.outWidth, bounds.outHeight) / (sampleSize * 2) >=
                    MAX_FHD_PREVIEW_EDGE
                ) {
                    sampleSize *= 2
                }
                val opts = BitmapFactory.Options().apply {
                    inPreferredConfig = config
                    inSampleSize = sampleSize
                }
                val orientation = if (honorExifOrientation) {
                    runCatching {
                        ExifInterface(ByteArrayInputStream(bytes)).getAttributeInt(
                            ExifInterface.TAG_ORIENTATION,
                            ExifInterface.ORIENTATION_NORMAL,
                        )
                    }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
                } else {
                    ExifInterface.ORIENTATION_NORMAL
                }
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)?.let { decoded ->
                    if (honorExifOrientation) applyExifOrientation(decoded, orientation) else decoded
                }?.let { displayBitmap ->
                    val longEdge = maxOf(displayBitmap.width, displayBitmap.height)
                    if (longEdge <= MAX_FHD_PREVIEW_EDGE) {
                        displayBitmap
                    } else {
                        val scale = MAX_FHD_PREVIEW_EDGE.toFloat() / longEdge
                        val scaled = Bitmap.createScaledBitmap(
                            displayBitmap,
                            (displayBitmap.width * scale).roundToInt().coerceAtLeast(1),
                            (displayBitmap.height * scale).roundToInt().coerceAtLeast(1),
                            true,
                        )
                        if (scaled !== displayBitmap) displayBitmap.recycle()
                        scaled
                    }
                }.also { bitmap ->
                    log {
                        "FHD ready handle=${file.handle} bytes=${bytes.size} " +
                            "effectOrientation=$honorExifOrientation/$orientation " +
                            "output=${bitmap?.width}x${bitmap?.height} " +
                            "queue+network=${receivedAt - startedAt}ms " +
                            "decode=${android.os.SystemClock.elapsedRealtime() - receivedAt}ms"
                    }
                }
            } catch (_: Exception) {
                null
            }
        }
    }

    /**
     * 加载文件的 EXIF 元数据（光圈/快门/ISO/焦距）。先从 [exifCache] 命中，
     * 未命中时通过 [NikonCamera.readExifHeader] 下载文件头 128KB，再用
     * [androidx.exifinterface.media.ExifInterface] 解析标准标签 + Nikon MakerNote。
     * 任何环节失败返回 null——EXIF 是纯体验增强，静默失败。
     */
    suspend fun loadExif(file: NikonCamera.FileInfo): PhotoExif? {
        val key = exifKey(file)
        // containsKey 区分"未尝试"与"已尝试但为 null（负缓存）"——?.let 无法区分。
        if (key in exifCache) return exifCache[key]
        // 非图片格式（视频、音频等）不包含 JPEG EXIF，直接负缓存避免浪费 PTP 请求。
        val ext = file.extension
        if (ext !in EXIF_SUPPORTED_EXTENSIONS) {
            exifCache[key] = null
            return null
        }
        val cam = camera ?: return null
        // 读取用会话级 handle（当下有效）；缓存键用稳定身份。
        // NEF/TIFF 等 RAW 格式的 MakerNote 可能位于较高偏移处，用更大 header 确保覆盖。
        val maxSize = if (ext in RAW_EXTENSIONS) 2048 * 1024 else 128 * 1024
        val bytes = cam.readExifHeader(file.handle, maxSize) ?: run {
            exifCache[key] = null
            return null
        }
        return parseExif(bytes)?.also { exifCache[key] = it }
            ?: run { exifCache[key] = null; null }
    }

    /**
     * 解析 ExifInterface RATIONAL/SRATIONAL 属性值（"num/denom" → Float）。
     * SHORT/LONG 等整数类型直接解析为 Float。null 或格式异常返回 null。
     */
    private fun parseRational(raw: String?): Float? {
        if (raw == null) return null
        val slash = raw.indexOf('/')
        return if (slash > 0) {
            val num = raw.substring(0, slash).toFloatOrNull() ?: return null
            val den = raw.substring(slash + 1).toFloatOrNull() ?: return null
            if (den == 0f) null else num / den
        } else {
            raw.toFloatOrNull()
        }
    }

    /**
     * 解析文件头字节中的 EXIF 数据。
     *
     * ExifInterface(InputStream) 文档明确仅支持 JPEG；对于 TIFF 派生格式
     * （NEF/NRW 等 Nikon RAW）流式构造在不同 Android 版本上行为不一致——
     * 部分版本静默返回空壳（不抛异常），导致回退路径永远不被触发。
     * 因此改为主**动检测 magic bytes**，TIFF 直接走临时文件 + ExifInterface(File)。
     */
    private suspend fun parseExif(headerBytes: ByteArray): PhotoExif? =
        withContext(Dispatchers.Default) {
            try {
                val exif = if (headerBytes.size >= 2
                    && headerBytes[0] == 0xFF.toByte() && headerBytes[1] == 0xD8.toByte()
                ) {
                    // JPEG → 流式构造是官方推荐路径
                    ExifInterface(ByteArrayInputStream(headerBytes))
                } else if (headerBytes.size >= 2
                    && ((headerBytes[0] == 'I'.code.toByte() && headerBytes[1] == 'I'.code.toByte())
                        || (headerBytes[0] == 'M'.code.toByte() && headerBytes[1] == 'M'.code.toByte()))
                ) {
                    // TIFF/NEF/NRW → 必须经文件路径构造；临时文件用完即删
                    val cacheDir = getApplication<android.app.Application>().cacheDir
                    val tmp = java.io.File.createTempFile("exif_", ".tif", cacheDir)
                    try {
                        tmp.writeBytes(headerBytes)
                        ExifInterface(tmp)
                    } finally {
                        tmp.delete()
                    }
                } else {
                    return@withContext null
                }
                parseExifImpl(exif)
            } catch (_: Exception) {
                null
            }
        }

    /** 从已构造的 [exif] 中提取标准 EXIF 参数。 */
    private fun parseExifImpl(exif: ExifInterface): PhotoExif? {
        // 光圈：优先 TAG_F_NUMBER（0x829D，直接的 f 值 RATIONAL，多数尼康机身填这个）；
        // 缺失时回退 TAG_APERTURE_VALUE（APEX 编码，f = 2^(apex/2)）。两者都试以免漏显。
        val fNumber = parseRational(exif.getAttribute(ExifInterface.TAG_F_NUMBER))
            ?: parseRational(exif.getAttribute(ExifInterface.TAG_APERTURE_VALUE))
                ?.let { apex -> Math.pow(2.0, apex.toDouble() / 2.0).toFloat() }
        val aperture = fNumber?.let { f -> if (f % 1f < 0.05f) "f/%.0f".format(f) else "f/%.1f".format(f) }

        // 快门：TAG_EXPOSURE_TIME 直接返回秒数 RATIONAL（如 "1/250"）
        val exposureTime = parseRational(exif.getAttribute(ExifInterface.TAG_EXPOSURE_TIME))
        val shutter = exposureTime?.let { sec ->
            if (sec >= 1f) "%.1fs".format(sec) else "1/%.0f".format(1f / sec)
        }

        // ISO：SHORT 整数
        val isoRaw = exif.getAttribute(ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY)
        val iso = if (isoRaw != null) "ISO$isoRaw" else null

        // 焦距：RATIONAL mm
        val focal = parseRational(exif.getAttribute(ExifInterface.TAG_FOCAL_LENGTH))
            ?.let { "%.0fmm".format(it) }

        // 图像尺寸：SHORT/LONG 整数
        return PhotoExif(aperture, shutter, iso, focal)
    }

    private fun diskFile(file: NikonCamera.FileInfo): File {
        val key = "${file.fileName}_${file.size}_${file.captureDate ?: "0"}"
            .replace(Regex("[^A-Za-z0-9._-]"), "_")
        return File(thumbDiskDir, "$key.jpg")
    }

    /** 先写临时文件再改名，避免进程被杀留下半截 JPEG 被当成有效缓存。仅 IO 线程调用。 */
    private fun writeAtomic(target: File, bytes: ByteArray) {
        try {
            // 系统设置"清除缓存"会把 thumbs 目录整个删掉且【不杀进程】：每次写入前
            // 重建目录，否则此后所有落盘静默失败、后台填充整个失效（实测踩过）。
            target.parentFile?.mkdirs()
            val tmp = File(target.parentFile, target.name + ".tmp")
            tmp.writeBytes(bytes)
            if (!tmp.renameTo(target)) tmp.delete()
        } catch (e: Exception) {
            log { "THUMB disk write failed ${target.name}: ${e.javaClass.simpleName}: ${e.message}" }
        }
    }

    /** 磁盘缓存超容时按最旧访问淘汰到 3/4 容量。启动时后台执行一次，平时零开销。 */
    private fun pruneThumbDisk() {
        try {
            val files = thumbDiskDir.listFiles() ?: return
            var total = files.sumOf { it.length() }
            if (total <= THUMB_DISK_MAX_BYTES) return
            for (f in files.sortedBy { it.lastModified() }) {
                total -= f.length()
                f.delete()
                if (total <= THUMB_DISK_MAX_BYTES * 3 / 4) break
            }
        } catch (_: Exception) {}
    }

    /** 仅 debug 构建输出缩略图链路日志（与协议层同 TAG，logcat 过滤 ZTransfer 即可）。 */
    private inline fun log(message: () -> String) {
        if (com.ztransfer.BuildConfig.DEBUG) {
            android.util.Log.d("ZTransfer", message())
        }
    }

    override fun onCleared() {
        super.onCleared()
        CameraSessionService.stop(getApplication())
        releaseSessionWifiLock()
        keepaliveJob?.cancel()
        watcherJob?.cancel()
        usbPermissionJob?.cancel()
        if (wifiHeld) releaseWifiNetworkRequest()
        if (usbReceiverRegistered) {
            runCatching { getApplication<Application>().unregisterReceiver(usbReceiver) }
            usbReceiverRegistered = false
        }
        val cam = camera
        camera = null
        // onCleared 时 viewModelScope 已取消，用独立作用域完成 socket 清理（close 内部为 NonCancellable）。
        cam?.let { cleanupScope.launch { it.close() } }
    }

    private companion object {
        const val ACTION_USB_PERMISSION = "com.ztransfer.USB_PERMISSION"
        const val USB_PERMISSION_TIMEOUT_MS = 20_000L
        const val USB_PERMISSION_POLL_MS = 100L
        const val USB_CONNECT_MAX_ATTEMPTS = 3
        const val KEEPALIVE_INTERVAL_MS = 10_000L
        // 事件轮询间隔:机身快门新照片出现在列表的最大延迟。单条小命令,
        // 相对 10s 心跳的通道占用可忽略;再快意义不大(拍完掏出手机也要几秒)。
        const val EVENT_POLL_INTERVAL_MS = 2_000L
        // 连接失败重试间隔：相机刚开热点时 PTP 服务可能晚于 Wi-Fi 就绪，快节奏重试
        // 让"差一步"的场景少等一秒；连续失败后降频，避免普通路由器恰好使用同网关时
        // 每秒空连。看护轮询只读本地 DHCP，保持 1 秒用于及时发现真正的网络切换。
        const val RETRY_INTERVAL_MS = 1_000L
        const val WIFI_BACKGROUND_RETRY_INTERVAL_MS = 3_000L
        const val WATCH_INTERVAL_MS = 1_000L
        const val EFFECT_PREVIEW_SETTLE_MS = 900L
        const val MAX_FHD_PREVIEW_EDGE = 1_920
        // 黑边判定：近黑像素的通道上限（JPEG 压缩后黑条并非纯黑，留噪声余量）；
        // 黑边占边长的上限——3:2 塞 4:3 为 5.6%、16:9 为 12.5%，超过 15% 视为画面本身偏暗。
        const val BAR_BLACK_MAX = 32
        const val BAR_MAX_FRACTION = 0.15f
        // 视频封面黑边兜底（cropVideoBars）：待裁带平均亮度上限。比 BAR_BLACK_MAX 略宽
        //（均值统计天然抗噪），但仍远低于正常画面暗部的均值。
        const val BAR_AVG_MAX = 40
        // 视频扩展名：封面黑边兜底裁切按 16:9 画面处理。
        // 注意与 PhotoPreview.kt 顶部的 VIDEO_EXTENSIONS（预览占位分支）保持同步。
        val VIDEO_EXTENSIONS = EFFECT_PREVIEW_VIDEO_EXTENSIONS
        // 缩略图磁盘缓存容量上限（原始 JPEG 每张几 KB，64MB 足够上万张）。
        const val THUMB_DISK_MAX_BYTES = 64L * 1024 * 1024
        // EXIF 解析支持的图片扩展名——视频/音频等格式不会有 EXIF 头。
        val EXIF_SUPPORTED_EXTENSIONS = setOf(".jpg", ".jpeg", ".nef", ".tif", ".tiff", ".nrw")
        // RAW 格式需要更大的 header（2MB）以确保 MakerNote 等嵌套 IFD 被完整覆盖。
        val RAW_EXTENSIONS = setOf(".nef", ".nrw", ".tif", ".tiff")
    }

    private data class Quad<A, B, C, D>(val first: A, val second: B, val third: C, val fourth: D)
    private data class Quint<A, B, C, D, E>(
        val first: A,
        val second: B,
        val third: C,
        val fourth: D,
        val fifth: E,
    )
}
