package com.nikon.transfer.viewmodel

import android.app.Application
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Job
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
    val cameraName: String? = null,
    val isConnecting: Boolean = false,
    val error: String? = null,
    val files: List<NikonCamera.FileInfo> = emptyList(),
    val isLoadingFiles: Boolean = false
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
                val onNikonWifi = isNikonWifi()
                // 顺带纠正 Wi-Fi 状态，避免回调漏报导致 UI 显示滞后。
                if (_state.value.isWifiConnected != onNikonWifi) {
                    _state.update { it.copy(isWifiConnected = onNikonWifi) }
                }
                if (onNikonWifi) {
                    if (!_state.value.isConnectedToCamera && !_state.value.isConnecting) {
                        connectToCameraWithRetry()
                    }
                } else if (_state.value.isConnectedToCamera || camera != null) {
                    forceDisconnect()   // 兜底：回调漏报时也能在掉线后断开
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
            val onNikonWifi = isNikonWifi()
            _state.update { it.copy(isWifiConnected = onNikonWifi) }

            if (onNikonWifi) {
                if (!_state.value.isConnectedToCamera && !_state.value.isConnecting) {
                    connectToCameraWithRetry()
                }
            } else if (_state.value.isConnectedToCamera || camera != null) {
                // Wi-Fi 掉线：立即断开相机，中断进行中的下载（由传输队列侧暂停并等待重连续传）。
                forceDisconnect()
            }
        }
    }

    /** Wi-Fi 掉线时主动断开：强制关闭 socket 以立即中断阻塞的下载读取，并置为未连接。 */
    private fun forceDisconnect() {
        val cam = camera
        camera = null
        keepaliveJob?.cancel()
        _state.update { it.copy(isConnectedToCamera = false, cameraName = null) }
        cam?.forceClose()                                    // 立即中断阻塞中的读
        cam?.let { cleanupScope.launch { it.close() } }      // 完整清理（幂等）
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
        _state.update { it.copy(isConnecting = true, error = null) }

        while (isNikonWifi() && !_state.value.isConnectedToCamera) {
            val cam = NikonCamera()
            var connected = false
            cam.connect().fold(
                onSuccess = { camName ->
                    camera = cam
                    _state.update {
                        it.copy(
                            isConnectedToCamera = true,
                            cameraName = camName,
                            isConnecting = false,
                            error = null
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

    fun connectToCamera() {
        viewModelScope.launch {
            connectToCameraWithRetry()
        }
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
                    _state.update {
                        it.copy(isConnectedToCamera = false, cameraName = null, files = emptyList())
                    }
                    viewModelScope.launch { connectToCameraWithRetry() }
                    break
                }
            }
        }
    }

    fun disconnect() {
        val cam = camera
        camera = null
        keepaliveJob?.cancel()
        _state.value = CameraState()
        cam?.let { cleanupScope.launch { it.close() } }
    }

    private fun loadFiles() {
        val cam = camera ?: return
        thumbnailCache.evictAll()   // 新会话/新列表，旧缩略图作废
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
            } catch (e: Exception) {
                _state.update { it.copy(isLoadingFiles = false, error = e.message ?: "加载文件失败") }
            }
        }
    }

    fun getCamera(): NikonCamera? = camera

    /**
     * 加载指定文件的缩略图（用于缩略图网格）。命中内存缓存直接返回；否则经 PTP GetThumb 取字节、
     * 在后台线程解码并入缓存。与下载共用 ioMutex，串行安全；相机未连接或无缩略图返回 null。
     *
     * @param allowFetch 为 false 时只读缓存、不发起新的 GetThumb —— 用于"传输进行中让路给下载"，
     *                   已缓存的缩略图仍会显示，未缓存的等队列空闲后再补载。
     */
    suspend fun loadThumbnail(handle: Int, allowFetch: Boolean = true): ImageBitmap? {
        thumbnailCache.get(handle)?.let { return it }
        if (!allowFetch) return null
        val cam = camera ?: return null
        return try {
            val bytes = cam.getThumbnail(handle) ?: return null
            val image = withContext(Dispatchers.Default) {
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
            } ?: return null
            thumbnailCache.put(handle, image)
            image
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e   // 滚动/传输开始导致的取消须传播，不能吞掉
        } catch (_: Exception) {
            null
        }
    }

    fun clearError() {
        _state.update { it.copy(error = null) }
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
        const val WATCH_INTERVAL_MS = 3_000L
    }
}
