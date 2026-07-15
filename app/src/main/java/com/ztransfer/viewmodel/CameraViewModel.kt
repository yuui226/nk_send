package com.ztransfer.viewmodel

import android.app.Application
import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.wifi.WifiManager
import android.os.Build
import android.util.LruCache
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.exifinterface.media.ExifInterface
import com.ztransfer.protocol.Lab
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.protocol.PtpConstants
import com.ztransfer.protocol.rcPollEvents
import java.io.ByteArrayInputStream
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
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
import kotlinx.coroutines.withContext
import java.io.File

data class CameraState(
    val isWifiConnected: Boolean = false,
    val isConnectedToCamera: Boolean = false,
    val isConnecting: Boolean = false,
    val files: List<NikonCamera.FileInfo> = emptyList(),
    val isLoadingFiles: Boolean = false,
    // 当前相机 Wi-Fi 的信号强度（dBm，典型 -30 强 ~ -90 弱）；未在相机 Wi-Fi 上时为 null。
    val wifiRssi: Int? = null
)

/**
 * 从相机文件头（JPEG EXIF）解析的照片参数。所有字段均可为 null——解析不到时静默缺省。
 * [afX]/[afY]/[afWidth]/[afHeight] 为**归一化坐标**（0..1，相对于原图像素尺寸），
 * 使用前需按 ContentScale 映射到显示区域。
 */
data class PhotoExif(
    val aperture: String?,       // "f/2.8"
    val shutterSpeed: String?,   // "1/250"
    val iso: String?,            // "400"
    val focalLength: String?,    // "50mm"
    /** 原始图像像素尺寸（用于 ContentScale.Fit 坐标映射）。 */
    val imageWidth: Int?,
    val imageHeight: Int?,
    // 对焦点信息（归一化坐标 0..1，相对原图尺寸）
    val afX: Float?,
    val afY: Float?,
    val afWidth: Float?,
    val afHeight: Float?
)

class CameraViewModel(application: Application) : AndroidViewModel(application) {
    private val _state = MutableStateFlow(CameraState())
    val state: StateFlow<CameraState> = _state.asStateFlow()

    private var camera: NikonCamera? = null
    private var keepaliveJob: Job? = null
    private var watcherJob: Job? = null
    private var eventPollJob: Job? = null

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
    // EXIF 缓存：键为【稳定身份】(文件名+大小+拍摄时间)，与磁盘缩略图缓存同口径——
    // 不用会话级 handle 作键，因 handle 跨会话/换卡会复用，否则重连后同一 handle 会把
    // 上一张照片的参数/对焦点串给新照片。null value = 已尝试但失败（负缓存）。
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

    // "是否有任务在传输"（含等待中）——后台缩略图填充的开关之一，由 UI 层喂入
    //（TransferViewModel 与本 VM 相互独立，经 MainScreen 桥接）。
    private val transfersBusyFlow = MutableStateFlow(false)

    fun setTransfersBusy(busy: Boolean) {
        transfersBusyFlow.value = busy
    }

    // 遥控页活跃期间同样完全停止填充：监看取帧是连续流量，填充的 GetThumb 会与
    // 参数加载/取帧争抢 ioMutex（表现为进页要等半天、帧率骤降）。与"传输中停止"
    // 同一哲学——前台交互独占通道；退出遥控页自动恢复。
    private val remoteActiveFlow = MutableStateFlow(false)

    fun setRemoteActive(active: Boolean) {
        remoteActiveFlow.value = active
    }

    // FHD 长按预览活跃期间暂停后台缩略图填充：FHD 取图比缩略图慢得多（1-3s vs 100ms），
    // 持续填充的 GetThumb 排队会把 FHD 请求憋在 ioMutex 队列后面、用户感知加载慢。
    // 与 remoteActive 同机制——前台交互独占通道；退出预览自动恢复。
    private val fhdActiveFlow = MutableStateFlow(false)

    fun setFhdActive(active: Boolean) {
        fhdActiveFlow.value = active
    }

    init {
        registerNetworkCallback()
        startConnectionWatcher()
        // 磁盘缓存超容淘汰（后台一次，不阻塞启动）。
        viewModelScope.launch(Dispatchers.IO) { pruneThumbDisk() }
        startThumbnailFill()
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
                fhdActiveFlow
            ) { files, busy, remote, fhd -> Quad(files, busy, remote, fhd) }.collectLatest { (files, busy, remote, fhd) ->
                if (busy || remote || fhd || files.isEmpty()) return@collectLatest
                // 展示序≈拍摄时间新→旧；无拍摄时间的排最后。
                val ordered = files.sortedByDescending { it.captureDate ?: "" }
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
     * 连接看护：只要未连上相机，就周期性检测手机是否已在相机 Wi-Fi 上，一旦在就立即发起连接。
     * 作为系统网络回调的兜底——部分机型回调触发晚或不稳定（DHCP 时序），此循环保证"手机一进
     * 相机 Wi-Fi 就连上"。isNikonWifi() 仅读本地 DHCP 网关，开销极小；只有确实在相机 Wi-Fi 上
     * 才会发起真正的 socket 连接，不在时不做任何无谓尝试（因此不在相机 Wi-Fi 上不会空耗电量）。
     */
    private fun startConnectionWatcher() {
        watcherJob?.cancel()
        watcherJob = viewModelScope.launch {
            while (isActive) {
                // dhcpInfo/connectionInfo 是 Binder IPC，放 IO 线程，不在主线程高频抖动。
                val (onNikonWifi, rssi) = withContext(Dispatchers.IO) {
                    val on = linkSaysCameraWifi || isNikonWifi()
                    on to (if (on) readRssi() else null)
                }
                // 顺带纠正 Wi-Fi 状态与信号强度，避免回调漏报导致 UI 显示滞后。
                if (_state.value.isWifiConnected != onNikonWifi || _state.value.wifiRssi != rssi) {
                    _state.update { it.copy(isWifiConnected = onNikonWifi, wifiRssi = rssi) }
                }
                // 同 onWifiChanged：只负责"在相机 Wi-Fi 上就连上"，绝不主动断开，避免误断打断传输。
                if (onNikonWifi && !_state.value.isConnectedToCamera && !_state.value.isConnecting) {
                    connectToCameraWithRetry()
                }
                delay(WATCH_INTERVAL_MS)
            }
        }
    }

    private fun registerNetworkCallback() {
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
    }

    private fun onWifiChanged() {
        viewModelScope.launch {
            val onNikonWifi = linkSaysCameraWifi || checkNikonWifi()
            _state.update { it.copy(isWifiConnected = onNikonWifi) }

            // 只在"已在相机 Wi-Fi 但尚未连上相机"时发起连接。
            // 绝不因 isNikonWifi()==false 主动断开：该判断依赖 dhcpInfo 网关，运行中可能瞬时误报，
            // 一旦在传输途中误断会不断打断并重传文件，速度暴跌。真正掉线由下载失败/心跳自然发现。
            if (onNikonWifi && !_state.value.isConnectedToCamera && !_state.value.isConnecting) {
                connectToCameraWithRetry()
            }
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
     * 持续尝试连接相机：只要还在相机 Wi-Fi 上就不断重试，直到连上为止，不再在若干次后报错。
     * 用户流程本就是"必须连上相机 Wi-Fi 才能用"，所以保持探测更符合预期。
     * 一旦离开相机网段则退出循环，由网络回调在重新连上 Wi-Fi 后再次触发。
     */
    private suspend fun connectToCameraWithRetry() {
        if (_state.value.isConnecting || _state.value.isConnectedToCamera) return
        _state.update { it.copy(isConnecting = true) }

        // 经 AppLocale.wrap：协议层错误文案（会显示在失败卡片上）与应用内语言一致。
        // 提到循环外：语言变更必经 Activity.recreate()，重试循环存续期间不可能变，
        // 不必每轮重试都重建配置上下文。
        val localizedContext = com.ztransfer.AppLocale.wrap(getApplication())
        while ((linkSaysCameraWifi || checkNikonWifi()) && !_state.value.isConnectedToCamera) {
            val cam = NikonCamera(localizedContext)
            var connected = false
            cam.connect(network = wifiNetwork).fold(
                onSuccess = {
                    camera = cam
                    acquireSessionWifiLock()   // 会话保活：连着就不让 Wi-Fi 打盹
                    _state.update {
                        it.copy(
                            isConnectedToCamera = true,
                            isConnecting = false
                        )
                    }
                    startKeepalive()
                    loadFiles()
                    startEventPolling()
                    connected = true
                },
                onFailure = {
                    cam.close()
                }
            )
            if (connected) return
            delay(RETRY_INTERVAL_MS)   // 未连上，稍后再试，不显示错误
        }

        // 已离开相机 Wi-Fi（或已连上）；清除"连接中"状态，等待下次网络变化再触发。
        _state.update { it.copy(isConnecting = false) }
    }

    /**
     * 周期性心跳：空闲时每 [KEEPALIVE_INTERVAL_MS] 探测一次相机，及时发现掉线并更新状态。
     * keepalive() 走 ioMutex，与下载/命令互斥，不会与进行中的传输产生并发冲突。
     */
    private fun startKeepalive() {
        keepaliveJob?.cancel()
        keepaliveJob = viewModelScope.launch {
            while (isActive) {
                delay(KEEPALIVE_INTERVAL_MS)
                val cam = camera ?: break
                if (!cam.keepalive()) {
                    camera = null
                    releaseSessionWifiLock()   // 会话结束，允许 Wi-Fi 恢复省电
                    cam.close()
                    // 掉线不报错，直接进入重连（新协程，避免与当前心跳协程的取消纠缠）。
                    // 不清空文件列表：网格保留（缩略图走缓存），断开状态由顶栏信号按钮
                    // 承担（红色断连图标），点击缩略图有抖动+提示反馈；重连后 loadFiles
                    // 整表刷新，不存在陈旧 handle 被使用的问题（点击已被连接检查挡住）。
                    _state.update {
                        it.copy(isConnectedToCamera = false)
                    }
                    viewModelScope.launch { connectToCameraWithRetry() }
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
                val dup = s.files.any {
                    it.handle == handle ||
                            (it.fileName == info.fileName && it.size == info.size &&
                                    it.captureDate == info.captureDate)
                }
                if (dup) s else s.copy(files = listOf(info) + s.files)
            }
        }
    }

    private fun loadFiles() {
        val cam = camera ?: return
        thumbnailCache.evictAll()   // 新会话/新列表，旧缩略图作废
        noThumbHandles.clear()      // handle 跨会话可能复用，负缓存一并作废
        _state.update { it.copy(isLoadingFiles = true, files = emptyList()) }

        viewModelScope.launch {
            try {
                // 双卡机型（Z5 II / Z6 III 等）：枚举【所有】存储卡的对象并合并，单卡机型
                // 行为不变。PTP StorageID 低 16 位为逻辑存储号，0 表示卡槽无卡，跳过；
                // handle 全机唯一、与卡无关，下载/缩略图等后续链路零改动。
                val storageIds = cam.getStorageIds().filter { it and 0xFFFF != 0 }
                if (storageIds.isEmpty()) {
                    _state.update { it.copy(isLoadingFiles = false) }
                    return@launch
                }

                val handles = storageIds.flatMap { cam.getObjectHandles(it) }.distinct()
                if (handles.isEmpty()) {
                    _state.update { it.copy(isLoadingFiles = false) }
                    return@launch
                }

                // handle 降序 ≈ 拍摄时间由新到旧；按批追加即可，最终展示顺序由
                // FileListScreen.groupFilesByDate 统一按日期分组排序，避免此处每批 O(n log n) 全量重排。
                // 双卡照片按拍摄日期自然混排进同一分组。
                val sortedHandles = handles.sortedDescending()
                val allFiles = mutableListOf<NikonCamera.FileInfo>()
                // 备份模式下同一张照片在两张卡各有一份（handle 不同）：按 名称+大小+拍摄时间
                // 去重，列表只显示一份；溢出/RAW+JPG 分卡等模式互不相同，不受影响。
                val seen = HashSet<String>()

                cam.streamFileInfo(sortedHandles, batchSize = 20) { batch, loaded, total ->
                    val fresh = batch.filter { seen.add("${it.fileName}|${it.size}|${it.captureDate}") }
                    allFiles.addAll(fresh)
                    val snapshot = allFiles.toList()
                    // onBatch 回调运行在 IO 线程，用 update 原子读改写避免与主线程写入竞争。
                    _state.update { it.copy(files = snapshot, isLoadingFiles = loaded < total) }
                }

                _state.update { it.copy(isLoadingFiles = false) }
            } catch (_: Exception) {
                // 扫描中断（掉线/读超时）：保留已加载的部分，掉线由心跳发现并触发重连。
                _state.update { it.copy(isLoadingFiles = false) }
            }
        }
    }

    fun getCamera(): NikonCamera? = camera

    /** 内存缓存的同步只读引用（未缓存返回 null,绝不发起取图）。仅主线程,与缓存同约束。 */
    fun cachedThumbnail(handle: Int): ImageBitmap? = thumbnailCache.get(handle)

    /**
     * 加载指定文件的缩略图（用于可见格子/预览/队列小图）。三级查找：
     * 内存 LRU → 磁盘缓存（毫秒级解码）→ 相机 GetThumb（取到即落盘 + 入内存）。
     * 确认无缩略图的负缓存直接返回 null。同 handle 的并发请求共享同一次取图。
     * 磁盘键是"文件名+大小+拍摄时间"的稳定身份，与会话级 handle 无关——断线重连
     * 后不必重新向相机拉图。相机未连接时磁盘命中仍可显示。
     *
     * 传输进行中也允许请求：ioMutex 在单个文件下载期间被持有，缩略图请求只会排队到
     * 当前文件传完的间隙执行，不会拖慢传输中的文件本身。
     */
    suspend fun loadThumbnail(file: NikonCamera.FileInfo): ImageBitmap? {
        val handle = file.handle
        thumbnailCache.get(handle)?.let { return it }
        if (handle in noThumbHandles) return null
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
        val cam = camera ?: return false
        val bytes = cam.getThumbnail(handle)   // 瞬时失败会抛出，由扫描循环按单张失败处理
        if (bytes == null || bytes.isEmpty()) {
            noThumbHandles.add(handle)
            return true
        }
        withContext(Dispatchers.IO) { writeAtomic(disk, bytes) }
        diskIndex?.add(disk.name)
        return true
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

    private suspend fun fetchAndDecodeThumb(file: NikonCamera.FileInfo): ImageBitmap? {
        val handle = file.handle
        return try {
            // 1) 磁盘缓存：按稳定身份键命中（跨会话/断连有效）。
            val disk = diskFile(file)
            var fromDisk = true
            var bytes = withContext(Dispatchers.IO) {
                if (disk.isFile) try { disk.readBytes() } catch (_: Exception) { null } else null
            }
            // 2) 相机取图，取到即落盘。
            if (bytes == null || bytes.isEmpty()) {
                fromDisk = false
                val cam = camera ?: return null
                bytes = cam.getThumbnail(handle)
                if (bytes == null || bytes.isEmpty()) {
                    noThumbHandles.add(handle)   // 相机明确表示无缩略图：负缓存，不再重试
                    log { "THUMB no-thumb handle=$handle (resp non-OK / empty)" }
                    return null
                }
                val fresh = bytes
                withContext(Dispatchers.IO) { writeAtomic(disk, fresh) }
                diskIndex?.add(disk.name)
            }
            val data = bytes
            val image = withContext(Dispatchers.Default) {
                // 解码后立即精确裁掉烘焙在缩略图里的黑边（3:2/16:9 塞 4:3 的上下黑条），
                // 裁好的位图进缓存——列表格子/队列小图/预览全都拿到无黑边的图，
                // UI 层不再需要"放大遮边"的近似 hack。
                BitmapFactory.decodeByteArray(data, 0, data.size)
                    ?.let { cropLetterbox(it) }
                    ?.asImageBitmap()
            }
            if (image == null) {
                // 解码失败：删掉磁盘上的坏文件。磁盘来源不负缓存（下次直接找相机重取）；
                // 相机新鲜字节都解不了才视为确认无图。
                withContext(Dispatchers.IO) { disk.delete() }
                diskIndex?.remove(disk.name)
                if (!fromDisk) noThumbHandles.add(handle)
                log { "THUMB decode failed handle=$handle bytes=${data.size} fromDisk=$fromDisk" }
                return null
            }
            thumbnailCache.put(handle, image)
            image
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            // IO 瞬时失败（掉线等）：不负缓存，重连后仍可加载
            log { "THUMB fetch failed handle=$handle: ${e.javaClass.simpleName}: ${e.message}" }
            null
        }
    }

    /**
     * 长按预览专用：加载 FHD (1920×1080) 预览图。直接从相机拉 FHD JPEG 并解码。
     * 任何环节失败均返回 null，调用方静默回退到缩略图。
     *
     * 不主动取消 inflightThumbs——后台填充已由 [setFhdActive] 暂停，PreviewPage
     * 自身的缩略图请求走 ioMutex 自然排队即可。强行 cancel 会杀掉 PreviewPage 的
     * LaunchedEffect（key 不变不复启），导致缩略图永久丢失、FHD 加载期间无占位图。
     *
     * FHD 图片不缓存（每次长按实时拉），预览关闭时 ImageBitmap 随 Composable 销毁释放。
     * 调用方应先通过 [setFhdActive] 暂停后台缩略图填充，再调用本方法。
     */
    suspend fun loadFhdPreview(file: NikonCamera.FileInfo): ImageBitmap? {
        val cam = camera ?: return null
        val bytes = try {
            cam.getFhdPicture(file.handle)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        } ?: return null

        return withContext(Dispatchers.Default) {
            try {
                // FHD 预览图是相机直出的 1920×1080 JPEG，非缩略图，不做黑边裁切。
                // 用 RGB_565 解码：不透明 JPEG 无需 alpha，2 字节/像素（1920×1080≈4MB，
                // 比 ARGB_8888 减半），屏幕预览肉眼无差别，多页预览内存峰值大降。
                val opts = BitmapFactory.Options().apply { inPreferredConfig = Bitmap.Config.RGB_565 }
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)?.asImageBitmap()
            } catch (_: Exception) {
                null
            }
        }
    }

    /**
     * 加载文件的 EXIF 元数据（光圈/快门/ISO/焦距/对焦点）。先从 [exifCache] 命中，
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

    /** 从已构造的 [exif] 中提取 EXIF 标签 + MakerNote 对焦点。 */
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
        val imgW = exif.getAttribute(ExifInterface.TAG_IMAGE_WIDTH)?.toIntOrNull()
        val imgH = exif.getAttribute(ExifInterface.TAG_IMAGE_LENGTH)?.toIntOrNull()

        // 对焦点：从 MakerNote 字节解析
        val af = imgW?.let { w -> imgH?.let { h -> parseNikonAfPoints(exif, w, h) } }

        return PhotoExif(aperture, shutter, iso, focal, imgW, imgH, af?.x, af?.y, af?.w, af?.h)
    }

    private data class AfCoords(val x: Float, val y: Float, val w: Float, val h: Float)

    /**
     * 从 Nikon MakerNote 字节中提取对焦点像素坐标，归一化到 [0..1]。
     *
     * 策略（3 级 fallback）：
     * 1. 尝试 ExifInterface 已知 Nikon 标签名（取决于 Android 版本）
     * 2. 解析 MakerNote TIFF IFD——遍历所有嵌套 IFD，搜索已知 AF tag IDs
     * 3. 扫描 MakerNote 中"长得像 AF 坐标"的相邻 SHORT 对
     * 全部失败返回 null → 对焦按钮隐藏。
     */
    private fun parseNikonAfPoints(exif: ExifInterface, imgW: Int, imgH: Int): AfCoords? {
        // 路径 1: ExifInterface 已知标签名：尝试已知的 Nikon 对焦点属性名
        fun attr(name: String): String? = try { exif.getAttribute(name) } catch (_: Exception) { null }
        val afX = attr("AFAreaXPosition") ?: attr("Nikon:AFAreaXPosition")
        val afY = attr("AFAreaYPosition") ?: attr("Nikon:AFAreaYPosition")
        val afW = attr("AFAreaWidth") ?: attr("Nikon:AFAreaWidth")
        val afH = attr("AFAreaHeight") ?: attr("Nikon:AFAreaHeight")
        if (afX != null && afY != null) {
            val x = afX.toFloatOrNull() ?: return null
            val y = afY.toFloatOrNull() ?: return null
            // 安全性：坐标必须在图像边界内
            if (x !in 0f..imgW.toFloat() || y !in 0f..imgH.toFloat()) return null
            val w = afW?.toFloatOrNull()?.takeIf { it in 10f..imgW.toFloat() / 2f } ?: 40f
            val h = afH?.toFloatOrNull()?.takeIf { it in 10f..imgH.toFloat() / 2f } ?: 40f
            return AfCoords(x / imgW, y / imgH, w / imgW, h / imgH)
        }

        // 路径 2: 解析 MakerNote IFD → 找 Tag 0x00B7 (AFInfo2) → 解析二进制块
        val makerNote = try { exif.getAttributeBytes("MakerNote") }
            catch (_: Exception) { null } ?: return null
        if (makerNote.size < 18 || makerNote[0] != 'N'.code.toByte()) return null

        // Nikon Type-3 MakerNote 头 = "Nikon\0"(0..5) + 版本(6..9) + 内嵌 TIFF 头【从偏移 10 起】：
        // 10..11 字节序标记(II/MM)、12..13 魔数 0x002A、14..17 IFD0 偏移。IFD 内的偏移均相对
        // 该 TIFF 头(偏移 10)。此前误用 tiffStart=6（读到版本字节），字节序恒判为大端、base 为
        // 垃圾值 → 路径 2 的 IFD 遍历永远失败。参考 exiftool Nikon.pm / exiv2 nikonmn_int.cpp。
        val tiffStart = 10
        val le = makerNote[tiffStart] == 0x49.toByte()

        fun ByteArray.u16(o: Int): Int {
            val a = this[o].toInt() and 0xFF; val b = this[o + 1].toInt() and 0xFF
            return if (le) a or (b shl 8) else (a shl 8) or b
        }
        fun ByteArray.u32(o: Int): Long {
            val a = this[o].toLong() and 0xFF; val b = this[o + 1].toLong() and 0xFF
            val c = this[o + 2].toLong() and 0xFF; val d = this[o + 3].toLong() and 0xFF
            return if (le) a or (b shl 8) or (c shl 16) or (d shl 24)
            else d or (c shl 8) or (b shl 16) or (a shl 24)
        }

        // 遍历 MakerNote IFD 找 Tag 0x00B7 (AFInfo2 二进制数据指针)
        val base = tiffStart + makerNote.u32(tiffStart + 4).toInt()
        var afOff = -1L; var afLen = 0L; val v = HashSet<Int>()

        fun findAf(dfBase: Int, d: Int) {
            if (d > 2 || dfBase < 0 || dfBase + 2 > makerNote.size || !v.add(dfBase)) return
            val n = makerNote.u16(dfBase)
            if (n == 0 || n > 256) return
            for (i in 0 until n) {
                val e = dfBase + 2 + i * 12
                if (e + 12 > makerNote.size) break
                if (makerNote.u16(e) == 0x00B7 && afOff < 0) {
                    afOff = tiffStart + makerNote.u32(e + 8); afLen = makerNote.u32(e + 4); return
                }
                if (makerNote.u16(e + 2).toInt() == 13) findAf(tiffStart + makerNote.u32(e + 8).toInt(), d + 1)
            }
            // 下一 IFD 指针紧随目录项之后（dfBase+2+n*12，共 4 字节）；越界则无后继目录。
            val nextPtrOff = dfBase + 2 + n * 12
            if (nextPtrOff + 4 > makerNote.size) return
            val nx = makerNote.u32(nextPtrOff).toInt()
            if (nx > 0) findAf(tiffStart + nx, d)
        }
        findAf(base, 0)

        if (afOff >= 0 && afLen >= 16) {
            parseAfInfo2(makerNote, afOff.toInt(), le, imgW, imgH, afLen.toInt())?.let { af -> return af }
        }

        // 路径 3: Tag 0x00B7 没找到——尝试在 MakerNote 中找到 AFInfo2 版本签名
        // ("0100"/"0200"/"0300") 然后从该位置解析。不传 len，由 parseAfInfo2 用保守策略。
        val verOff = findAfInfo2Signature(makerNote, tiffStart)
        if (verOff >= 0) {
            parseAfInfo2(makerNote, verOff, le, imgW, imgH)?.let { af -> return af }
        }
        return null
    }

    /**
     * 扫描 MakerNote 查找 AFInfo2 版本签名 ("0100" / "0200" / "0300")。
     * 返回签名在 makerNote 中的偏移，未找到返回 -1。
     */
    private fun findAfInfo2Signature(makerNote: ByteArray, start: Int): Int {
        for (i in start until makerNote.size - 4) {
            val b0 = makerNote[i].toInt() and 0xFF
            val b1 = makerNote[i + 1].toInt() and 0xFF
            val b2 = makerNote[i + 2].toInt() and 0xFF
            val b3 = makerNote[i + 3].toInt() and 0xFF
            // "0100" / "0200" / "0300" — Nikon AFInfo2 已知版本号
            //（用范围判断而非 listOf：此循环对 2MB RAW header 逐字节跑，勿在热路径每字节建表装箱）
            if (b0 == '0'.code && b2 == '0'.code && b3 == '0'.code && b1 >= '1'.code && b1 <= '3'.code) {
                return i
            }
        }
        return -1
    }

    /**
     * 解析 AFInfo2 二进制数据块 (MakerNote Tag 0x00B7)。
     *
     * AFInfo2 结构末尾 12 字节固定为:
     *   [AFImageWidth:2] [AFImageHeight:2] [AFAreaXPosition:2] [AFAreaYPosition:2] [AFAreaWidth:2] [AFAreaHeight:2]
     *
     * 当 [len] 已知时，从数据块末端回扫——头部可变长字段（版本号、属性、AFPointsUsed
     * 长度因机身和 AF 区域模式不同而剧烈变化）不再需要猜测偏移。
     * [len] 未知时使用保守前向扫描，但校验阈值比旧版严格得多。
     * 参考: exiftool Nikon.pm / exiv2 nikonmn_int.cpp
     */
    private fun parseAfInfo2(data: ByteArray, off: Int, le: Boolean, imgW: Int, imgH: Int, len: Int? = null): AfCoords? {
        fun ByteArray.u16(o: Int): Int {
            if (o < 0 || o + 1 >= this.size) return -1
            val a = this[o].toInt() and 0xFF; val b = this[o + 1].toInt() and 0xFF
            return if (le) a or (b shl 8) else (a shl 8) or b
        }

        // ---- 路径 A: 已知长度 → 从数据块末端回扫 ----
        if (len != null && len >= 16) {
            val blockEnd = off + len
            // 从后往前扫（步进 2 字节），AF 区 6 字段是连续 12 字节。
            // 注意 AFInfo2 内 AF 区字段之后可能还有少量扩展字段，不能只假定在最后 12 字节。
            // 因此扫描范围覆盖整个块（跳过前 4 字节版本号），从末尾逐对 uint16 向前匹配。
            for (cursor in blockEnd - 12 downTo off + 4 step 2) {
                val dimW = data.u16(cursor)
                val dimH = data.u16(cursor + 2)
                // AFImageWidth/Height 必须贴近实际图像尺寸（±25%，覆盖 DX 裁切）
                if (dimW < imgW * 3 / 4 || dimW > imgW * 5 / 4) continue
                if (dimH < imgH * 3 / 4 || dimH > imgH * 5 / 4) continue
                val x = data.u16(cursor + 4)
                val y = data.u16(cursor + 6)
                if (x !in 0 until dimW || y !in 0 until dimH) continue
                val w = data.u16(cursor + 8)
                val h = data.u16(cursor + 10)
                // 单点 AF 区域通常 50–500px，最多不超过画面 1/3
                if (w < 20 || w > dimW / 3 || h < 20 || h > dimH / 3) continue
                return AfCoords(x.toFloat() / dimW, y.toFloat() / dimH, w.toFloat() / dimW, h.toFloat() / dimH)
            }
            // 精确回扫没命中 → 在已知边界内做前向扫描兜底
        }

        // ---- 路径 B: 长度未知或回扫未命中 → 在限定范围内前向扫描 ----
        val scanEnd = if (len != null) minOf(off + len - 10, data.size - 2) else minOf(off + 200, data.size - 2)
        if (scanEnd <= off + 12) return null
        for (i in off + 4 until scanEnd step 2) {
            val dimW = data.u16(i)
            val dimH = data.u16(i + 2)
            if (dimW < imgW * 3 / 4 || dimW > imgW * 5 / 4) continue
            if (dimH < imgH * 3 / 4 || dimH > imgH * 5 / 4) continue
            val x = data.u16(i + 4)
            val y = data.u16(i + 6)
            if (x !in 0 until dimW || y !in 0 until dimH) continue
            val w = data.u16(i + 8).coerceAtLeast(1)
            val h = data.u16(i + 10).coerceAtLeast(1)
            if (w < 20 || w > dimW / 3 || h < 20 || h > dimH / 3) continue
            return AfCoords(x.toFloat() / dimW, y.toFloat() / dimH, w.toFloat() / dimW, h.toFloat() / dimH)
        }
        return null
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
        releaseSessionWifiLock()
        keepaliveJob?.cancel()
        watcherJob?.cancel()
        try {
            connectivityManager.unregisterNetworkCallback(networkCallback)
        } catch (_: Exception) {}
        val cam = camera
        camera = null
        // onCleared 时 viewModelScope 已取消，用独立作用域完成 socket 清理（close 内部为 NonCancellable）。
        cam?.let { cleanupScope.launch { it.close() } }
    }

    private companion object {
        const val KEEPALIVE_INTERVAL_MS = 10_000L
        // 事件轮询间隔:机身快门新照片出现在列表的最大延迟。单条小命令,
        // 相对 10s 心跳的通道占用可忽略;再快意义不大(拍完掏出手机也要几秒)。
        const val EVENT_POLL_INTERVAL_MS = 2_000L
        // 连接失败重试间隔：相机刚开热点时 PTP 服务可能晚于 Wi-Fi 就绪，快节奏重试
        // 让"差一步"的场景少等一秒。看护轮询同理（开销只是读本地 DHCP，可忽略）。
        const val RETRY_INTERVAL_MS = 1_000L
        const val WATCH_INTERVAL_MS = 1_000L
        // 黑边判定：近黑像素的通道上限（JPEG 压缩后黑条并非纯黑，留噪声余量）；
        // 黑边占边长的上限——3:2 塞 4:3 为 5.6%、16:9 为 12.5%，超过 15% 视为画面本身偏暗。
        const val BAR_BLACK_MAX = 32
        const val BAR_MAX_FRACTION = 0.15f
        // 缩略图磁盘缓存容量上限（原始 JPEG 每张几 KB，64MB 足够上万张）。
        const val THUMB_DISK_MAX_BYTES = 64L * 1024 * 1024
        // EXIF 解析支持的图片扩展名——视频/音频等格式不会有 EXIF 头。
        val EXIF_SUPPORTED_EXTENSIONS = setOf(".jpg", ".jpeg", ".nef", ".tif", ".tiff", ".nrw")
        // RAW 格式需要更大的 header（2MB）以确保 MakerNote 等嵌套 IFD 被完整覆盖。
        val RAW_EXTENSIONS = setOf(".nef", ".nrw", ".tif", ".tiff")
    }

    private data class Quad<A, B, C, D>(val first: A, val second: B, val third: C, val fourth: D)
}
