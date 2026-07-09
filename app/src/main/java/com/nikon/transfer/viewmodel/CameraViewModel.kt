package com.nikon.transfer.viewmodel

import android.app.Application
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.wifi.WifiManager
import android.util.LruCache
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.nikon.transfer.protocol.NikonCamera
import com.nikon.transfer.protocol.PtpConstants
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
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class CameraState(
    val isWifiConnected: Boolean = false,
    val isConnectedToCamera: Boolean = false,
    val isConnecting: Boolean = false,
    val files: List<NikonCamera.FileInfo> = emptyList(),
    val isLoadingFiles: Boolean = false,
    // 当前相机 Wi-Fi 的信号强度（dBm，典型 -30 强 ~ -90 弱）；未在相机 Wi-Fi 上时为 null。
    val wifiRssi: Int? = null
)

class CameraViewModel(application: Application) : AndroidViewModel(application) {
    private val _state = MutableStateFlow(CameraState())
    val state: StateFlow<CameraState> = _state.asStateFlow()

    private var camera: NikonCamera? = null
    private var keepaliveJob: Job? = null
    private var watcherJob: Job? = null

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
    // 用于连接清理等需在 viewModelScope 取消后仍完成的一次性 IO。
    private val cleanupScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val connectivityManager = application.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    @Suppress("DEPRECATION")
    private val wifiManager = application.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            onWifiChanged()
        }

        override fun onLost(network: Network) {
            onWifiChanged()
        }

        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            onWifiChanged()
        }
    }

    init {
        registerNetworkCallback()
        startConnectionWatcher()
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
                // dhcpInfo/connectionInfo 是 Binder IPC，放 IO 线程，不在主线程每 1.5s 抖一下。
                val (onNikonWifi, rssi) = withContext(Dispatchers.IO) {
                    val on = isNikonWifi()
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
        connectivityManager.registerNetworkCallback(request, networkCallback)
    }

    private fun onWifiChanged() {
        viewModelScope.launch {
            val onNikonWifi = checkNikonWifi()
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

        while (checkNikonWifi() && !_state.value.isConnectedToCamera) {
            val cam = NikonCamera()
            var connected = false
            cam.connect().fold(
                onSuccess = {
                    camera = cam
                    _state.update {
                        it.copy(
                            isConnectedToCamera = true,
                            isConnecting = false
                        )
                    }
                    startKeepalive()
                    loadFiles()
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

    private fun loadFiles() {
        val cam = camera ?: return
        thumbnailCache.evictAll()   // 新会话/新列表，旧缩略图作废
        noThumbHandles.clear()      // handle 跨会话可能复用，负缓存一并作废
        _state.update { it.copy(isLoadingFiles = true, files = emptyList()) }

        viewModelScope.launch {
            try {
                val storageIds = cam.getStorageIds()
                if (storageIds.isEmpty()) {
                    _state.update { it.copy(isLoadingFiles = false) }
                    return@launch
                }

                val handles = cam.getObjectHandles(storageIds.first())
                if (handles.isEmpty()) {
                    _state.update { it.copy(isLoadingFiles = false) }
                    return@launch
                }

                // handle 降序 ≈ 拍摄时间由新到旧；按批追加即可，最终展示顺序由
                // FileListScreen.groupFilesByDate 统一按日期分组排序，避免此处每批 O(n log n) 全量重排。
                val sortedHandles = handles.sortedDescending()
                val allFiles = mutableListOf<NikonCamera.FileInfo>()

                cam.streamFileInfo(sortedHandles, batchSize = 20) { batch, loaded, total ->
                    allFiles.addAll(batch)
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

    /**
     * 加载指定文件的缩略图（用于缩略图网格）。命中内存缓存直接返回；确认无缩略图的负缓存直接
     * 返回 null；否则经 PTP GetThumb 取字节、在后台线程解码并入缓存。同 handle 的并发请求
     * 共享同一次取图。与下载共用 ioMutex，串行安全；相机未连接返回 null。
     *
     * 传输进行中也允许请求：ioMutex 在单个文件下载期间被持有，缩略图请求只会排队到
     * 当前文件传完的间隙执行，不会拖慢传输中的文件本身。"传输期间少取图"由 UI 层
     * 收窄预取窗口实现（见 FileListScreen 的 PREFETCH_AHEAD_BUSY），已缓存即静默。
     */
    suspend fun loadThumbnail(handle: Int): ImageBitmap? {
        thumbnailCache.get(handle)?.let { return it }
        if (handle in noThumbHandles) return null
        // 复用进行中的请求（跳过已被取消但尚未从表中清理的条目）。
        val entry = inflightThumbs[handle]?.takeIf { !it.deferred.isCancelled } ?: run {
            val cam = camera ?: return null
            InflightThumb(viewModelScope.async { fetchAndDecodeThumb(cam, handle) })
                .also { inflightThumbs[handle] = it }
        }
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

    private suspend fun fetchAndDecodeThumb(cam: NikonCamera, handle: Int): ImageBitmap? {
        return try {
            val bytes = cam.getThumbnail(handle)
            if (bytes == null || bytes.isEmpty()) {
                noThumbHandles.add(handle)   // 相机明确表示无缩略图：负缓存，不再重试
                log { "THUMB no-thumb handle=$handle (resp non-OK / empty)" }
                return null
            }
            val image = withContext(Dispatchers.Default) {
                // 解码后立即精确裁掉烘焙在缩略图里的黑边（3:2/16:9 塞 4:3 的上下黑条），
                // 裁好的位图进缓存——列表格子/队列小图/预览全都拿到无黑边的图，
                // UI 层不再需要"放大遮边"的近似 hack。
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                    ?.let { cropLetterbox(it) }
                    ?.asImageBitmap()
            }
            if (image == null) {
                noThumbHandles.add(handle)   // 字节取到但解码失败：同样视为无缩略图
                log { "THUMB decode failed handle=$handle bytes=${bytes.size}" }
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

    /** 仅 debug 构建输出缩略图链路日志（与协议层同 TAG，logcat 过滤 NikonTransfer 即可）。 */
    private inline fun log(message: () -> String) {
        if (com.nikon.transfer.BuildConfig.DEBUG) {
            android.util.Log.d("NikonTransfer", message())
        }
    }

    override fun onCleared() {
        super.onCleared()
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
        const val RETRY_INTERVAL_MS = 2_000L
        const val WATCH_INTERVAL_MS = 1_500L
        // 黑边判定：近黑像素的通道上限（JPEG 压缩后黑条并非纯黑，留噪声余量）；
        // 黑边占边长的上限——3:2 塞 4:3 为 5.6%、16:9 为 12.5%，超过 15% 视为画面本身偏暗。
        const val BAR_BLACK_MAX = 32
        const val BAR_MAX_FRACTION = 0.15f
    }
}
