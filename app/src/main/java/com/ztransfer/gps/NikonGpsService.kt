package com.ztransfer.gps

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.location.Geocoder
import android.os.Build
import android.os.IBinder
import android.os.Looper
import androidx.core.content.ContextCompat
import androidx.core.app.NotificationCompat
import com.ztransfer.MainActivity
import com.ztransfer.R
import java.time.Instant
import java.util.Locale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

internal object NikonGpsRuntime {
    val state = MutableStateFlow(GpsState())
}

@SuppressLint("MissingPermission")
class NikonGpsService : Service(), NikonGpsBleClient.Listener {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var locationManager: LocationManager
    private lateinit var bleClient: NikonGpsBleClient
    private lateinit var preferences: android.content.SharedPreferences
    private var reconnectJob: Job? = null
    private var lastSentLocation: Location? = null
    private var lastSentAt = 0L
    private var pendingSentLocation: Location? = null
    private var geoWriteInFlight = false
    private var geoWriteTimeoutJob: Job? = null
    private var lastGeocodedKey: String? = null
    private var geocodeJob: Job? = null
    private var enabled = false
    private var cameraReady = false
    private var apModeBlocked = false
    private var preserveReadyDuringReconnect = false

    private val locationListener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            if (!enabled || !cameraReady) return
            NikonGpsRuntime.state.update {
                it.copy(
                    latitude = location.latitude,
                    longitude = location.longitude,
                    accuracyMeters = location.accuracy,
                    status = if (it.status == GpsStatus.READY ||
                        it.status == GpsStatus.WRITING ||
                        it.status == GpsStatus.ERROR
                    ) {
                        it.status
                    } else {
                        GpsStatus.WAITING_FIX
                    },
                    message = if (it.status == GpsStatus.ERROR) it.message else null,
                )
            }
            requestPlaceName(location)
            maybeSend(location)
        }
    }

    override fun onCreate() {
        super.onCreate()
        locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        preferences = getSharedPreferences(PREFERENCES, MODE_PRIVATE)
        bleClient = NikonGpsBleClient(this, serviceScope, this)
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_SET_AP_MODE) {
            apModeBlocked = intent.getBooleanExtra(EXTRA_AP_MODE, false)
            if (apModeBlocked) {
                enabled = preferences.getBoolean(KEY_ENABLED, false)
                stopActiveConnection()
                if (enabled) updateState(GpsStatus.AP_UNAVAILABLE, message = "AP 模式不可用")
                else stopSelf()
            } else if (preferences.getBoolean(KEY_ENABLED, false)) {
                enabled = true
                startForegroundCompat()
                if (enabled) startGpsIfPermitted()
            } else {
                stopSelf()
            }
            return START_STICKY
        }
        if (intent?.action == ACTION_DISABLE) {
            stopGps()
            stopSelf()
            return START_NOT_STICKY
        }
        // START_STICKY may restart the service with a null intent. Respect the persisted
        // switch instead of silently re-enabling GPS after the user turned it off.
        if (intent?.action != ACTION_ENABLE && !preferences.getBoolean(KEY_ENABLED, false)) {
            stopSelf()
            return START_NOT_STICKY
        }
        enabled = true
        startForegroundCompat()
        if (!enabled) return START_NOT_STICKY
        if (apModeBlocked) {
            updateState(GpsStatus.AP_UNAVAILABLE, message = "AP 模式不可用")
            return START_STICKY
        }
        startGpsIfPermitted()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopGps()
        serviceScope.cancel()
        super.onDestroy()
    }

    override fun onConnecting(name: String?) {
        GpsDiagnostics.record("connecting name=${name ?: "?"}")
        updateState(GpsStatus.CONNECTING, name ?: "Nikon")
    }

    override fun onBleAddress(address: String) {
        preferences.edit().putString(KEY_BLE_ADDRESS, address).apply()
        GpsDiagnostics.record("BLE address saved=$address")
    }

    override fun onPairing() {
        GpsDiagnostics.record("BLE pairing handshake")
        updateState(GpsStatus.PAIRING)
    }

    override fun onReady(name: String, device: android.bluetooth.BluetoothDevice) {
        GpsDiagnostics.record("GPS ready camera=$name")
        reconnectJob?.cancel()
        reconnectJob = null
        cameraReady = true
        preserveReadyDuringReconnect = false
        updateState(GpsStatus.CONNECTED, name)
        startLocationUpdates()
    }

    override fun onGeoWritten(success: Boolean) {
        GpsDiagnostics.record("GEO write success=$success")
        geoWriteTimeoutJob?.cancel()
        geoWriteTimeoutJob = null
        geoWriteInFlight = false
        if (success) {
            reconnectJob?.cancel()
            reconnectJob = null
            pendingSentLocation?.let { sent -> lastSentLocation = Location(sent) }
            pendingSentLocation = null
            lastSentAt = System.currentTimeMillis()
            NikonGpsRuntime.state.update {
                it.copy(status = GpsStatus.READY, lastSentAtMs = lastSentAt, message = null)
            }
        } else {
            pendingSentLocation = null
            lastSentLocation = null
            lastSentAt = 0L
            updateState(GpsStatus.ERROR, message = "GPS 写入失败")
        }
    }

    override fun onPairedIdentity(device: Long, nonce: Long) {
        preferences.edit()
            .putLong(KEY_DEVICE_ID, device)
            .putLong(KEY_NONCE, nonce)
            .apply()
        updateState(GpsStatus.PAIRING_SUCCESS, message = "配对成功")
    }

    override fun onDisconnected() {
        if (!enabled) return
        cameraReady = false
        stopLocationUpdates()
        // Force the first location after a reconnect to be sent again. The camera may have
        // dropped its GPS channel together with GATT even when the coordinates did not change.
        lastSentLocation = null
        lastSentAt = 0L
        pendingSentLocation = null
        geoWriteInFlight = false
        geoWriteTimeoutJob?.cancel()
        geoWriteTimeoutJob = null
        val currentStatus = NikonGpsRuntime.state.value.status
        val pairingCompleted = currentStatus == GpsStatus.PAIRING_SUCCESS
        preserveReadyDuringReconnect = currentStatus == GpsStatus.READY
        if (!pairingCompleted && !preserveReadyDuringReconnect) {
            updateState(GpsStatus.CONNECTING, message = "正在重连")
        }
        reconnectJob?.cancel()
        reconnectJob = serviceScope.launch {
            // The Classic bond callback already confirms the camera; a short settle time is
            // enough before scanning the camera's fresh random BLE address.
            if (pairingCompleted) {
                delay(700)
                if (isActive && enabled) updateState(GpsStatus.CONNECTING, message = "正在连接")
            }
            delay(if (pairingCompleted) 100 else 800)
            if (isActive && enabled) startBle()
        }
    }

    override fun onNeedsPairing() {
        GpsDiagnostics.record("awaiting Classic pairing")
        updateState(GpsStatus.CAMERA_CONFIRM, message = "请在相机上按 OK")
    }

    override fun onError(message: String) {
        GpsDiagnostics.record("error=$message")
        cameraReady = false
        preserveReadyDuringReconnect = false
        if (message.contains("pairing rejected", ignoreCase = true) ||
            message.contains("identity expired", ignoreCase = true)
        ) {
            // The camera may have forgotten its side of the bond. Drop the cached identity so
            // the next attempt starts a clean pairing handshake instead of retrying stale data.
            preferences.edit()
                .remove(KEY_DEVICE_ID)
                .remove(KEY_NONCE)
                .remove(KEY_BLE_ADDRESS)
                .apply()
            GpsDiagnostics.record("cached pairing identity cleared")
        }
        if (!enabled) return
        val userMessage = when {
            message.contains("permission", ignoreCase = true) -> "需要蓝牙权限"
            message.contains("not found", ignoreCase = true) ||
                message.contains("pairing rejected", ignoreCase = true) ||
                message.contains("identity expired", ignoreCase = true) -> "请在相机上打开蓝牙配对"
            message.contains("Bluetooth unavailable", ignoreCase = true) -> "请打开手机蓝牙"
            message.contains("scan failed", ignoreCase = true) -> "请打开手机蓝牙"
            else -> message
        }
        val needsCamera = userMessage.contains("配对") ||
            userMessage.contains("not found", ignoreCase = true)
        val isPermissionError = userMessage.contains("权限")
        updateState(
            if (isPermissionError) GpsStatus.ERROR
            else if (needsCamera) GpsStatus.NEEDS_CAMERA
            else GpsStatus.ERROR,
            message = userMessage,
        )
        if (enabled && !isPermissionError) {
            reconnectJob?.cancel()
            reconnectJob = serviceScope.launch {
                // A failed GATT setup can leave a non-null connection object on some Android
                // stacks; clear it before retrying so start() cannot be short-circuited.
                bleClient.stop()
                delay(5_000)
                if (isActive && enabled) startBle()
            }
        }
    }

    private fun startGpsIfPermitted() {
        if (apModeBlocked) {
            updateState(GpsStatus.AP_UNAVAILABLE, message = "AP 模式不可用")
            return
        }
        val bluetoothOkay = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED
        val connectOkay = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
        if (!bluetoothOkay || !connectOkay) {
            updateState(GpsStatus.ERROR, message = "需要蓝牙权限")
            return
        }
        updateState(GpsStatus.STARTING)
        startBle()
    }

    private fun startBle() {
        if (apModeBlocked) {
            updateState(GpsStatus.AP_UNAVAILABLE, message = "AP 模式不可用")
            return
        }
        cameraReady = false
        val storedId = preferences.getLong(KEY_DEVICE_ID, Long.MIN_VALUE)
            .takeUnless { it == Long.MIN_VALUE }
        val storedNonce = preferences.getLong(KEY_NONCE, Long.MIN_VALUE)
            .takeUnless { it == Long.MIN_VALUE }
        val hasCompleteIdentity = storedId != null && storedNonce != null
        if (!hasCompleteIdentity && (storedId != null || storedNonce != null)) {
            preferences.edit()
                .remove(KEY_DEVICE_ID)
                .remove(KEY_NONCE)
                .remove(KEY_BLE_ADDRESS)
                .apply()
            GpsDiagnostics.record("incomplete pairing identity cleared")
        }
        val savedId = storedId.takeIf { hasCompleteIdentity }
        val savedNonce = storedNonce.takeIf { hasCompleteIdentity }
        val savedBleAddress = preferences.getString(KEY_BLE_ADDRESS, null)
        if (!preserveReadyDuringReconnect) {
            updateState(if (hasCompleteIdentity) GpsStatus.CONNECTING else GpsStatus.SEARCHING)
        }
        bleClient.start(savedDeviceId = savedId, savedNonce = savedNonce, savedBleAddress = savedBleAddress)
    }

    private fun startLocationUpdates() {
        val fine = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (!fine && !coarse) {
            updateState(GpsStatus.ERROR, message = "需要定位权限")
            return
        }
        val gpsEnabled = runCatching { locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER) }.getOrDefault(false)
        val networkEnabled = runCatching { locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER) }.getOrDefault(false)
        if (!gpsEnabled && !networkEnabled) {
            updateState(GpsStatus.ERROR, message = "请打开手机定位")
            return
        }
        stopLocationUpdates()
        runCatching {
            if (gpsEnabled && locationManager.getProvider(LocationManager.GPS_PROVIDER) != null) {
                locationManager.requestLocationUpdates(LocationManager.GPS_PROVIDER, 5_000L, 3f, locationListener, Looper.getMainLooper())
            }
            if (networkEnabled && locationManager.getProvider(LocationManager.NETWORK_PROVIDER) != null) {
                locationManager.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, 15_000L, 3f, locationListener, Looper.getMainLooper())
            }
            // Reuse a recent system fix immediately instead of waiting for the next provider
            // callback. This closes the small window where the user can shoot before the first
            // GPS payload reaches the camera.
            val now = System.currentTimeMillis()
            val cached = listOfNotNull(
                if (gpsEnabled) runCatching { locationManager.getLastKnownLocation(LocationManager.GPS_PROVIDER) }.getOrNull() else null,
                if (networkEnabled) runCatching { locationManager.getLastKnownLocation(LocationManager.NETWORK_PROVIDER) }.getOrNull() else null,
            ).filter { location ->
                location.time > 0L && kotlin.math.abs(now - location.time) <= CACHED_LOCATION_MAX_AGE_MS
            }.maxByOrNull { it.time }
            cached?.let(locationListener::onLocationChanged)
        }.onFailure { updateState(GpsStatus.ERROR, message = "无法获取定位") }
    }

    private fun stopLocationUpdates() {
        runCatching { locationManager.removeUpdates(locationListener) }
    }

    private fun maybeSend(location: Location) {
        if (!enabled || geoWriteInFlight) return
        val previous = lastSentLocation
        val moved = previous == null || location.distanceTo(previous) >= 3f
        val due = System.currentTimeMillis() - lastSentAt >= 20_000L
        if (!moved && !due) return
        val satellites = location.extras?.getInt("satellites", 0) ?: 0
        val payload = runCatching {
            GeoPayloadEncoder.encode(
                latitude = location.latitude,
                longitude = location.longitude,
                altitudeMeters = location.altitude,
                satellites = satellites,
                timestamp = Instant.now(),
            )
        }.getOrNull() ?: return
        geoWriteInFlight = true
        pendingSentLocation = Location(location)
        updateState(GpsStatus.WRITING)
        GpsDiagnostics.record("GEO queued provider=${location.provider ?: "?"} accuracy=${location.accuracy.toInt()}m")
        bleClient.writeGeo(payload)
        geoWriteTimeoutJob?.cancel()
        geoWriteTimeoutJob = serviceScope.launch {
            delay(GEO_WRITE_TIMEOUT_MS)
            if (geoWriteInFlight && enabled) {
                geoWriteInFlight = false
                pendingSentLocation = null
                lastSentLocation = null
                lastSentAt = 0L
                onError("GPS write timeout")
            }
        }
    }

    private fun stopGps() {
        enabled = false
        cameraReady = false
        preserveReadyDuringReconnect = false
        reconnectJob?.cancel()
        reconnectJob = null
        pendingSentLocation = null
        geoWriteInFlight = false
        geoWriteTimeoutJob?.cancel()
        geoWriteTimeoutJob = null
        lastSentLocation = null
        lastSentAt = 0L
        stopLocationUpdates()
        if (::bleClient.isInitialized) bleClient.stop()
        geocodeJob?.cancel()
        geocodeJob = null
        lastGeocodedKey = null
        NikonGpsRuntime.state.value = GpsState()
    }

    private fun stopActiveConnection() {
        cameraReady = false
        preserveReadyDuringReconnect = false
        reconnectJob?.cancel()
        reconnectJob = null
        pendingSentLocation = null
        geoWriteInFlight = false
        geoWriteTimeoutJob?.cancel()
        geoWriteTimeoutJob = null
        lastSentLocation = null
        lastSentAt = 0L
        stopLocationUpdates()
        if (::bleClient.isInitialized) bleClient.stop()
        NikonGpsRuntime.state.update { it.copy(enabled = enabled, status = GpsStatus.AP_UNAVAILABLE, message = "AP 模式不可用") }
    }

    private fun requestPlaceName(location: Location) {
        if (!Geocoder.isPresent()) return
        val key = "%.3f,%.3f".format(Locale.US, location.latitude, location.longitude)
        if (key == lastGeocodedKey) return
        lastGeocodedKey = key
        geocodeJob?.cancel()
        geocodeJob = serviceScope.launch(Dispatchers.IO) {
            val place = runCatching {
                Geocoder(this@NikonGpsService, Locale.getDefault())
                    .getFromLocation(location.latitude, location.longitude, 1)
                    ?.firstOrNull()
                    ?.let { address ->
                        address.getAddressLine(0)
                            ?.takeIf { it.isNotBlank() }
                            ?: address.featureName
                            ?: address.thoroughfare
                            ?: address.locality
                            ?: address.subLocality
                            ?: address.adminArea
                    }
            }.getOrNull()?.takeIf { it.isNotBlank() }
            if (place != null) {
                NikonGpsRuntime.state.update { state ->
                    if (state.latitude == location.latitude && state.longitude == location.longitude) {
                        state.copy(placeName = place)
                    } else state
                }
            }
        }
    }

    private fun updateState(status: GpsStatus, cameraName: String? = null, message: String? = null) {
        NikonGpsRuntime.state.update {
            it.copy(enabled = enabled, status = status, cameraName = cameraName ?: it.cameraName, message = message)
        }
    }

    private fun startForegroundCompat() {
        val notification = buildNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
                startForeground(NOTIFICATION_ID, notification, type)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: SecurityException) {
            updateState(GpsStatus.ERROR, message = "需要通知权限")
            enabled = false
            preferences.edit().putBoolean(KEY_ENABLED, false).apply()
            stopSelf()
        }
    }

    private fun createNotificationChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "GPS", NotificationManager.IMPORTANCE_LOW))
    }

    private fun buildNotification(): Notification = NotificationCompat.Builder(this, CHANNEL_ID)
        .setSmallIcon(R.drawable.ic_stat_transfer)
        .setContentTitle("Z传 GPS")
        .setContentText("自动写入相机位置")
        .setOngoing(true)
        .setSilent(true)
        .setContentIntent(android.app.PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE))
        .build()

    companion object {
        private const val CHANNEL_ID = "nikon_gps"
        private const val NOTIFICATION_ID = 1003
        private const val CACHED_LOCATION_MAX_AGE_MS = 2 * 60_000L
        private const val GEO_WRITE_TIMEOUT_MS = 10_000L
        const val ACTION_ENABLE = "com.ztransfer.gps.ENABLE"
        const val ACTION_DISABLE = "com.ztransfer.gps.DISABLE"
        private const val PREFERENCES = "nikon_gps"
        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_NONCE = "nonce"
        private const val KEY_BLE_ADDRESS = "ble_address"
        private const val KEY_ENABLED = "enabled"
        const val ACTION_SET_AP_MODE = "com.ztransfer.gps.SET_AP_MODE"
        const val EXTRA_AP_MODE = "ap_mode"

        fun setEnabled(context: Context, enabled: Boolean) {
            val intent = Intent(context, NikonGpsService::class.java).setAction(if (enabled) ACTION_ENABLE else ACTION_DISABLE)
            if (enabled) ContextCompat.startForegroundService(context, intent) else context.startService(intent)
        }

        fun setApModeBlocked(context: Context, blocked: Boolean) {
            // The connection screens report the current transport mode when they
            // compose.  Do not let the initial "not AP" report resurrect a
            // previously enabled GPS service during app launch; only an already
            // running service (or an explicit user enable) may be resumed.
            if (!blocked && !NikonGpsRuntime.state.value.enabled) return
            val intent = Intent(context, NikonGpsService::class.java)
                .setAction(ACTION_SET_AP_MODE)
                .putExtra(EXTRA_AP_MODE, blocked)
            context.startService(intent)
        }
    }
}
