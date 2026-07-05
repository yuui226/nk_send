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
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
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
            _state.value = _state.value.copy(isWifiConnected = connected)

            if (connected && !_state.value.isConnectedToCamera && !_state.value.isConnecting) {
                connectToCameraWithRetry()
            }
        }
    }

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
        _state.value = _state.value.copy(isConnecting = true, error = null)

        repeat(maxRetries) { attempt ->
            val cam = NikonCamera()
            val result = cam.connect()
            result.fold(
                onSuccess = { camName ->
                    camera = cam
                    _state.value = _state.value.copy(
                        isConnectedToCamera = true,
                        cameraName = camName,
                        isConnecting = false,
                        error = null
                    )
                    loadFiles()
                    return
                },
                onFailure = { e ->
                    cam.close()
                    if (attempt < maxRetries - 1) {
                        delay(2000L)
                    } else {
                        _state.value = _state.value.copy(
                            isConnecting = false,
                            error = "连接失败 (${maxRetries}次重试): ${e.message}"
                        )
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

    fun disconnect() {
        camera?.close()
        camera = null
        _state.value = CameraState()
    }

    private fun loadFiles() {
        val cam = camera ?: return
        _state.value = _state.value.copy(isLoadingFiles = true, files = emptyList())

        viewModelScope.launch {
            try {
                val storageIds = cam.getStorageIds()
                if (storageIds.isEmpty()) {
                    _state.value = _state.value.copy(isLoadingFiles = false)
                    return@launch
                }

                val handles = cam.getObjectHandles(storageIds.first())
                if (handles.isEmpty()) {
                    _state.value = _state.value.copy(isLoadingFiles = false)
                    return@launch
                }

                val sortedHandles = handles.sortedDescending()
                val allFiles = mutableListOf<NikonCamera.FileInfo>()

                cam.streamFileInfo(sortedHandles, batchSize = 20) { batch, loaded, total ->
                    allFiles.addAll(batch)
                    val sorted = allFiles.sortedByDescending { it.captureDate ?: "" }
                    _state.value = _state.value.copy(
                        files = sorted.toList(),
                        isLoadingFiles = loaded < total
                    )
                }

                _state.value = _state.value.copy(isLoadingFiles = false)
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    isLoadingFiles = false,
                    error = e.message ?: "加载文件失败"
                )
            }
        }
    }

    fun getCamera(): NikonCamera? = camera

    fun clearError() {
        _state.value = _state.value.copy(error = null)
    }

    override fun onCleared() {
        super.onCleared()
        try {
            connectivityManager.unregisterNetworkCallback(networkCallback)
        } catch (_: Exception) {}
        camera?.close()
    }
}
