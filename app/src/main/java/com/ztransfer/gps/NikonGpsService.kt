package com.ztransfer.gps

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
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
    private var lastSentAt = 0L
    private var geoWriteInFlight = false
    private var geoWriteTimeoutJob: Job? = null
    private var readyUiJob: Job? = null
    private var lastGeocodedKey: String? = null
    private var geocodeJob: Job? = null
    private var enabled = false
    private var cameraReady = false
    private var cameraVerified = false
    private var pairingConfirmationPending = false
    private var apModeBlocked = false
    private var preserveReadyDuringReconnect = false
    private var bluetoothOff = false
    private var bluetoothReceiverRegistered = false

    private val bluetoothReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                BluetoothAdapter.STATE_OFF,
                BluetoothAdapter.STATE_TURNING_OFF -> handleBluetoothOff()
                BluetoothAdapter.STATE_ON -> handleBluetoothOn()
            }
        }
    }
    private var notificationStarted = false
    private var notificationOverride: String? = null

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
                        it.status == GpsStatus.CONNECTED ||
                        it.status == GpsStatus.CONNECTING ||
                        it.status == GpsStatus.PAIRING_SUCCESS ||
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
        registerBluetoothReceiver()
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
        unregisterBluetoothReceiver()
        serviceScope.cancel()
        super.onDestroy()
    }

    private fun registerBluetoothReceiver() {
        if (bluetoothReceiverRegistered) return
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(bluetoothReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(bluetoothReceiver, filter)
        }
        bluetoothReceiverRegistered = true
        bluetoothOff = !isBluetoothEnabled()
    }

    private fun unregisterBluetoothReceiver() {
        if (!bluetoothReceiverRegistered) return
        runCatching { unregisterReceiver(bluetoothReceiver) }
        bluetoothReceiverRegistered = false
    }

    private fun isBluetoothEnabled(): Boolean = runCatching {
        (getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)
            ?.adapter
            ?.isEnabled == true
    }.getOrDefault(false)

    private fun handleBluetoothOff() {
        if (bluetoothOff) return
        bluetoothOff = true
        reconnectJob?.cancel()
        reconnectJob = null
        readyUiJob?.cancel()
        readyUiJob = null
        cameraReady = false
        cameraVerified = false
        pairingConfirmationPending = false
        lastSentAt = 0L
        geoWriteInFlight = false
        geoWriteTimeoutJob?.cancel()
        geoWriteTimeoutJob = null
        stopLocationUpdates()
        if (::bleClient.isInitialized) bleClient.stop()
        if (enabled) {
            if (apModeBlocked) {
                updateState(GpsStatus.AP_UNAVAILABLE, message = "AP 模式不可用")
            } else {
                updateState(GpsStatus.ERROR, message = "请打开手机蓝牙")
            }
        }
        GpsDiagnostics.record("Bluetooth adapter off; GPS paused")
    }

    private fun handleBluetoothOn() {
        if (!bluetoothOff) return
        bluetoothOff = false
        if (!enabled || apModeBlocked) return
        reconnectJob?.cancel()
        reconnectJob = null
        notificationOverride = null
        GpsDiagnostics.record("Bluetooth adapter on; GPS resumed")
        startGpsIfPermitted()
    }

    override fun onConnecting(name: String?) {
        GpsDiagnostics.record("connecting name=${name ?: "?"}")
        notificationOverride = null
        // A verified session may briefly lose GATT when the camera sleeps. Keep the
        // stable READY presentation during background reconnect; onReady() restores it
        // only after the ID handshake succeeds again. A first-time scan has no saved
        // identity yet, so it must stay in SEARCHING until the pairing stage begins.
        if (preserveReadyDuringReconnect && hasCompleteSavedIdentity()) {
            updateState(GpsStatus.READY, name ?: "Nikon", message = "正在重连")
        } else {
            updateState(
                if (hasCompleteSavedIdentity()) GpsStatus.CONNECTING else GpsStatus.SEARCHING,
                name ?: "Nikon",
            )
        }
    }

    override fun onBleAddress(address: String) {
        preferences.edit().putString(KEY_BLE_ADDRESS, address).apply()
        GpsDiagnostics.record("BLE address saved=$address")
    }

    override fun onPairing() {
        GpsDiagnostics.record("BLE pairing handshake")
        notificationOverride = null
        updateState(GpsStatus.PAIRING)
    }

    override fun onReady(name: String, device: android.bluetooth.BluetoothDevice) {
        GpsDiagnostics.record("GPS ready camera=$name")
        notificationOverride = null
        reconnectJob?.cancel()
        reconnectJob = null
        val wasReadyBeforeReconnect = preserveReadyDuringReconnect
        cameraReady = true
        cameraVerified = wasReadyBeforeReconnect
        preserveReadyDuringReconnect = false
        // ID write success confirms the saved-pairing link is available. Keep READY gated
        // by the first GEO write so a connected camera without a valid location fix never
        // appears as fully enabled.
        updateState(
            if (wasReadyBeforeReconnect) GpsStatus.READY else GpsStatus.CONNECTED,
            name,
            null,
        )
        startLocationUpdates()
    }

    override fun onGeoWritten(success: Boolean) {
        GpsDiagnostics.record("GEO write success=$success")
        geoWriteTimeoutJob?.cancel()
        geoWriteTimeoutJob = null
        geoWriteInFlight = false
        if (success) {
            notificationOverride = "位置已更新 · ${formatNotificationTime(System.currentTimeMillis())}"
            val firstVerifiedWrite = !cameraVerified
            val confirmedFreshPairing = pairingConfirmationPending
            cameraVerified = true
            pairingConfirmationPending = false
            if (firstVerifiedWrite) {
                GpsDiagnostics.record("camera connection verified by GEO write")
            }
            reconnectJob?.cancel()
            reconnectJob = null
            lastSentAt = System.currentTimeMillis()
            if (firstVerifiedWrite) {
                NikonGpsRuntime.state.update {
                    it.copy(
                        status = if (confirmedFreshPairing) GpsStatus.PAIRING_SUCCESS else GpsStatus.CONNECTED,
                        lastSentAtMs = lastSentAt,
                        message = null,
                    )
                }
                readyUiJob?.cancel()
                readyUiJob = serviceScope.launch {
                    if (confirmedFreshPairing) {
                        delay(650)
                        if (!enabled || !cameraReady ||
                            NikonGpsRuntime.state.value.status != GpsStatus.PAIRING_SUCCESS
                        ) return@launch
                        NikonGpsRuntime.state.update { it.copy(status = GpsStatus.CONNECTED) }
                    }
                    delay(700)
                    if (enabled && cameraReady && NikonGpsRuntime.state.value.status == GpsStatus.CONNECTED) {
                        NikonGpsRuntime.state.update { it.copy(status = GpsStatus.READY) }
                    }
                }
            } else {
                NikonGpsRuntime.state.update {
                    it.copy(status = GpsStatus.READY, lastSentAtMs = lastSentAt, message = null)
                }
            }
            refreshNotification()
        } else {
            lastSentAt = 0L
            updateState(GpsStatus.ERROR, message = "GPS 写入失败")
            notificationOverride = "GPS 写入失败"
            refreshNotification()
        }
    }

    override fun onPairedIdentity(device: Long, nonce: Long) {
        preferences.edit()
            .putLong(KEY_DEVICE_ID, device)
            .putLong(KEY_NONCE, nonce)
            .apply()
        // Android's Classic bond can exist before the camera has committed its side of the
        // pairing. Cache the identity, but do not report success until the reconnected camera
        // accepts the first GEO write.
        pairingConfirmationPending = true
        GpsDiagnostics.record("Classic bond ready; awaiting camera GEO verification")
        updateState(GpsStatus.CONNECTING, message = "正在确认配对")
    }

    override fun onDisconnected() {
        if (!enabled) return
        notificationOverride = "连接已断开，正在重连"
        refreshNotification()
        cameraReady = false
        stopLocationUpdates()
        // Force the first location after a reconnect to be sent again. The camera may have
        // dropped its GPS channel together with GATT even when the coordinates did not change.
        lastSentAt = 0L
        geoWriteInFlight = false
        geoWriteTimeoutJob?.cancel()
        geoWriteTimeoutJob = null
        readyUiJob?.cancel()
        readyUiJob = null
        val currentStatus = NikonGpsRuntime.state.value.status
        val pairingCompleted = currentStatus == GpsStatus.PAIRING_SUCCESS
        preserveReadyDuringReconnect = currentStatus == GpsStatus.READY
        cameraVerified = false
        if (bluetoothOff || !isBluetoothEnabled()) {
            bluetoothOff = true
            preserveReadyDuringReconnect = false
            updateState(GpsStatus.ERROR, message = "请打开手机蓝牙")
            return
        }
        if (!pairingCompleted && !preserveReadyDuringReconnect) {
            val hasIdentity = hasCompleteSavedIdentity()
            updateState(
                if (hasIdentity) GpsStatus.CONNECTING else GpsStatus.SEARCHING,
                message = if (hasIdentity) "正在重连" else null,
            )
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
        cameraVerified = false
        preserveReadyDuringReconnect = false
        pairingConfirmationPending = false
        readyUiJob?.cancel()
        readyUiJob = null
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
        notificationOverride = userMessage
        updateState(
            if (isPermissionError) GpsStatus.ERROR
            else if (needsCamera) GpsStatus.NEEDS_CAMERA
            else GpsStatus.ERROR,
            message = userMessage,
        )
        if (enabled && !isPermissionError && !bluetoothOff && isBluetoothEnabled()) {
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
        if (bluetoothOff || !isBluetoothEnabled()) {
            bluetoothOff = true
            updateState(GpsStatus.ERROR, message = "请打开手机蓝牙")
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
        if (bluetoothOff || !isBluetoothEnabled()) {
            bluetoothOff = true
            updateState(GpsStatus.ERROR, message = "请打开手机蓝牙")
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

    private fun hasCompleteSavedIdentity(): Boolean =
        preferences.getLong(KEY_DEVICE_ID, Long.MIN_VALUE) != Long.MIN_VALUE &&
            preferences.getLong(KEY_NONCE, Long.MIN_VALUE) != Long.MIN_VALUE

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
                locationManager.requestLocationUpdates(LocationManager.GPS_PROVIDER, 5_000L, 0f, locationListener, Looper.getMainLooper())
            }
            if (networkEnabled && locationManager.getProvider(LocationManager.NETWORK_PROVIDER) != null) {
                locationManager.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, 15_000L, 0f, locationListener, Looper.getMainLooper())
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
        if (System.currentTimeMillis() - lastSentAt < LOCATION_WRITE_INTERVAL_MS) return
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
        updateState(GpsStatus.WRITING)
        GpsDiagnostics.record("GEO queued provider=${location.provider ?: "?"} accuracy=${location.accuracy.toInt()}m")
        bleClient.writeGeo(payload)
        geoWriteTimeoutJob?.cancel()
        geoWriteTimeoutJob = serviceScope.launch {
            delay(GEO_WRITE_TIMEOUT_MS)
            if (geoWriteInFlight && enabled) {
                geoWriteInFlight = false
                lastSentAt = 0L
                onError("GPS write timeout")
            }
        }
    }

    private fun stopGps() {
        enabled = false
        cameraReady = false
        cameraVerified = false
        pairingConfirmationPending = false
        preserveReadyDuringReconnect = false
        reconnectJob?.cancel()
        reconnectJob = null
        geoWriteInFlight = false
        geoWriteTimeoutJob?.cancel()
        geoWriteTimeoutJob = null
        readyUiJob?.cancel()
        readyUiJob = null
        lastSentAt = 0L
        stopLocationUpdates()
        if (::bleClient.isInitialized) bleClient.stop()
        geocodeJob?.cancel()
        geocodeJob = null
        lastGeocodedKey = null
        notificationOverride = null
        if (notificationStarted) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION") stopForeground(true)
            }
            notificationStarted = false
        }
        NikonGpsRuntime.state.value = GpsState()
    }

    private fun stopActiveConnection() {
        cameraReady = false
        cameraVerified = false
        pairingConfirmationPending = false
        preserveReadyDuringReconnect = false
        reconnectJob?.cancel()
        reconnectJob = null
        geoWriteInFlight = false
        geoWriteTimeoutJob?.cancel()
        geoWriteTimeoutJob = null
        readyUiJob?.cancel()
        readyUiJob = null
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
        refreshNotification()
    }

    private fun startForegroundCompat() {
        val notification = buildNotification(NikonGpsRuntime.state.value)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
                startForeground(NOTIFICATION_ID, notification, type)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            notificationStarted = true
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

    private fun buildNotification(state: GpsState): Notification = NotificationCompat.Builder(this, CHANNEL_ID)
        .setSmallIcon(R.drawable.ic_stat_transfer)
        .setContentTitle("Z传 GPS")
        .setContentText(notificationOverride ?: notificationText(state))
        .setOngoing(true)
        .setSilent(true)
        .setContentIntent(android.app.PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE))
        .build()

    private fun refreshNotification() {
        if (!notificationStarted) return
        runCatching {
            getSystemService(NotificationManager::class.java)
                .notify(NOTIFICATION_ID, buildNotification(NikonGpsRuntime.state.value))
        }
    }

    private fun notificationText(state: GpsState): String = when (state.status) {
        GpsStatus.OFF -> "GPS 已关闭"
        GpsStatus.STARTING, GpsStatus.SEARCHING -> "正在寻找相机"
        GpsStatus.NEEDS_CAMERA -> state.message ?: "请打开相机蓝牙"
        GpsStatus.CONNECTING -> state.message ?: "正在连接相机"
        GpsStatus.PAIRING, GpsStatus.CAMERA_CONFIRM, GpsStatus.PAIRING_SUCCESS -> "正在连接相机"
        GpsStatus.CONNECTED -> "已连接，等待位置更新"
        GpsStatus.WRITING -> "正在写入相机位置"
        GpsStatus.WAITING_FIX -> "等待定位"
        GpsStatus.READY -> "已连接，自动写入位置"
        GpsStatus.AP_UNAVAILABLE -> "AP 模式不可用"
        GpsStatus.ERROR -> state.message ?: "GPS 连接失败"
    }

    private fun formatNotificationTime(timestamp: Long): String =
        java.text.SimpleDateFormat("HH:mm", Locale.getDefault()).format(java.util.Date(timestamp))

    companion object {
        private const val CHANNEL_ID = "nikon_gps"
        private const val NOTIFICATION_ID = 1003
        private const val CACHED_LOCATION_MAX_AGE_MS = 2 * 60_000L
        private const val LOCATION_WRITE_INTERVAL_MS = 60_000L
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
