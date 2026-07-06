package com.nikon.transfer.viewmodel

import android.app.Application
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
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
            // 不主动关闭，等心跳超时自然断开
        }

        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            onWifiChanged()
        }
    }

    init {
        registerNetworkCallback()
    }

    private fun registerNetworkCallback() {
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()
        connectivityManager.registerNetworkCallback(request, networkCallback)
    }

    private fun onWifiChanged() {
        viewModelScope.launch {
            val connected = isNikonWifi()
            _state.update { it.copy(isWifiConnected = connected) }

            if (connected && !_state.value.isConnectedToCamera && !_state.value.isConnecting) {
                connectToCameraWithRetry()
            }
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

    private suspend fun connectToCameraWithRetry(maxRetries: Int = 3) {
        if (_state.value.isConnecting || _state.value.isConnectedToCamera) return
        _state.update { it.copy(isConnecting = true, error = null) }

        repeat(maxRetries) { attempt ->
            val cam = NikonCamera()
            val result = cam.connect()
            result.fold(
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
                    return
                },
                onFailure = { e ->
                    cam.close()
                    if (attempt < maxRetries - 1) {
                        delay(2000L)
                    } else {
                        _state.update {
                            it.copy(
                                isConnecting = false,
                                error = "连接失败 (${maxRetries}次重试): ${e.message}"
                            )
                        }
                    }
                }
            )
        }
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
                    _state.update {
                        it.copy(
                            isConnectedToCamera = false,
                            cameraName = null,
                            files = emptyList(),
                            error = "与相机的连接已断开"
                        )
                    }
                    cam.close()
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

    fun clearError() {
        _state.update { it.copy(error = null) }
    }

    override fun onCleared() {
        super.onCleared()
        keepaliveJob?.cancel()
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
    }
}
