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
import android.os.Build
import android.os.IBinder
import android.os.Looper
import androidx.core.content.ContextCompat
import androidx.core.app.NotificationCompat
import com.ztransfer.MainActivity
import com.ztransfer.R
import java.time.Instant
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
    private var lastLocation: Location? = null
    private var lastSentLocation: Location? = null
    private var lastSentAt = 0L
    private var enabled = false

    private val locationListener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            lastLocation = location
            NikonGpsRuntime.state.update {
                it.copy(
                    latitude = location.latitude,
                    longitude = location.longitude,
                    accuracyMeters = location.accuracy,
                    status = if (it.status == GpsStatus.READY) it.status else GpsStatus.WAITING_FIX,
                    message = null,
                )
            }
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

    override fun onReady(name: String, device: android.bluetooth.BluetoothDevice) {
        GpsDiagnostics.record("GPS ready camera=$name")
        updateState(GpsStatus.WAITING_FIX, name)
        startLocationUpdates()
    }

    override fun onGeoWritten(success: Boolean) {
        GpsDiagnostics.record("GEO write success=$success")
        if (success) {
            NikonGpsRuntime.state.update { it.copy(status = GpsStatus.READY, message = null) }
        } else {
            updateState(GpsStatus.ERROR, message = "GPS 写入失败")
        }
    }

    override fun onPairedIdentity(device: Long, nonce: Long) {
        preferences.edit()
            .putLong(KEY_DEVICE_ID, device)
            .putLong(KEY_NONCE, nonce)
            .apply()
    }

    override fun onDisconnected() {
        if (!enabled) return
        stopLocationUpdates()
        updateState(GpsStatus.CONNECTING, message = "正在重连")
        reconnectJob?.cancel()
        reconnectJob = serviceScope.launch {
            // The Classic bond callback already confirms the camera; a short settle time is
            // enough before scanning the camera's fresh random BLE address.
            delay(800)
            if (isActive && enabled) startBle()
        }
    }

    override fun onNeedsPairing() {
        GpsDiagnostics.record("awaiting Classic pairing")
        updateState(GpsStatus.CONNECTING, message = "请确认蓝牙配对")
    }

    override fun onError(message: String) {
        GpsDiagnostics.record("error=$message")
        if (!enabled) return
        val userMessage = when {
            message.contains("permission", ignoreCase = true) -> "需要蓝牙权限"
            message.contains("not found", ignoreCase = true) -> "请在相机上打开蓝牙配对"
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
        val savedId = preferences.getLong(KEY_DEVICE_ID, Long.MIN_VALUE)
            .takeUnless { it == Long.MIN_VALUE }
        val savedNonce = preferences.getLong(KEY_NONCE, Long.MIN_VALUE)
            .takeUnless { it == Long.MIN_VALUE }
        bleClient.start(savedDeviceId = savedId, savedNonce = savedNonce)
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
        runCatching {
            if (gpsEnabled && locationManager.getProvider(LocationManager.GPS_PROVIDER) != null) {
                locationManager.requestLocationUpdates(LocationManager.GPS_PROVIDER, 5_000L, 3f, locationListener, Looper.getMainLooper())
            }
            if (networkEnabled && locationManager.getProvider(LocationManager.NETWORK_PROVIDER) != null) {
                locationManager.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, 15_000L, 3f, locationListener, Looper.getMainLooper())
            }
        }.onFailure { updateState(GpsStatus.ERROR, message = "无法获取定位") }
    }

    private fun stopLocationUpdates() {
        runCatching { locationManager.removeUpdates(locationListener) }
    }

    private fun maybeSend(location: Location) {
        if (!enabled) return
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
                timestamp = Instant.ofEpochMilli(location.time.coerceAtLeast(1L)),
            )
        }.getOrNull() ?: return
        bleClient.writeGeo(payload)
        lastSentLocation = location
        lastSentAt = System.currentTimeMillis()
        NikonGpsRuntime.state.update { it.copy(lastSentAtMs = lastSentAt) }
    }

    private fun stopGps() {
        enabled = false
        reconnectJob?.cancel()
        reconnectJob = null
        stopLocationUpdates()
        if (::bleClient.isInitialized) bleClient.stop()
        NikonGpsRuntime.state.value = GpsState()
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
        const val ACTION_ENABLE = "com.ztransfer.gps.ENABLE"
        const val ACTION_DISABLE = "com.ztransfer.gps.DISABLE"
        private const val PREFERENCES = "nikon_gps"
        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_NONCE = "nonce"
        private const val KEY_ENABLED = "enabled"

        fun setEnabled(context: Context, enabled: Boolean) {
            val intent = Intent(context, NikonGpsService::class.java).setAction(if (enabled) ACTION_ENABLE else ACTION_DISABLE)
            if (enabled) ContextCompat.startForegroundService(context, intent) else context.startService(intent)
        }
    }
}
