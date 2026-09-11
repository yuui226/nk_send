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
import android.os.Build
import android.os.IBinder
import android.os.Looper
import androidx.core.content.ContextCompat
import androidx.core.app.NotificationCompat
import com.ztransfer.BuildConfig
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
    private var latestLocationDuringWrite: Location? = null
    private var geoWriteInFlight = false
    private var geoWriteTimeoutJob: Job? = null
    /** Periodically replays the latest fix so the 60 s cadence is independent of provider callbacks. */
    private var periodicGeoWriteJob: Job? = null
    private var latestLocation: Location? = null
    private var pendingAltitudeRefresh = false
    private var altitudeUnavailableLogged = false
    private var latestTrustedAltitudeFix: Location? = null
    private var readyUiJob: Job? = null
    private var enabled = false
    private var cameraReady = false
    private var cameraVerified = false
    private var pairingConfirmationPending = false
    private var apModeBlocked = false
    private var preserveReadyDuringReconnect = false
    private var bluetoothOff = false
    /** Pairing failures wait for an explicit user retry; never reopen the system bond dialog. */
    private var awaitingPairingUserAction = false
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
            // Some vendor network providers mark a synthetic 0 m altitude as present. Only a
            // recent GPS fix establishes altitude; nearby network coordinates may reuse it.
            val altitude = resolveAltitude(location)
            val payloadLocation = Location(location).apply {
                if (altitude != null) setAltitude(altitude) else removeAltitude()
            }
            val previousTrustedAltitude = NikonGpsRuntime.state.value.altitudeMeters
            NikonGpsRuntime.state.update {
                it.copy(
                    latitude = location.latitude,
                    longitude = location.longitude,
                    altitudeMeters = altitude,
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
            latestLocation = Location(payloadLocation)
            maybeSend(
                payloadLocation,
                force = shouldForceTrustedAltitudeRefresh(previousTrustedAltitude, altitude),
            )
        }
    }

    private fun resolveAltitude(location: Location): Double? {
        val nowMs = System.currentTimeMillis()
        trustedAltitudeFix(location, nowMs)?.let { altitude ->
            latestTrustedAltitudeFix = Location(location)
            return altitude
        }
        val cachedFix = latestTrustedAltitudeFix ?: return null
        val distanceMeters = runCatching { cachedFix.distanceTo(location) }
            .getOrDefault(Float.POSITIVE_INFINITY)
        if (!canReuseGpsAltitude(nowMs, cachedFix.time, distanceMeters)) return null
        return trustedGpsAltitude(
            provider = cachedFix.provider,
            hasAltitude = cachedFix.hasAltitude(),
            altitudeMeters = cachedFix.altitude,
        )
    }

    private fun trustedAltitudeFix(location: Location, nowMs: Long): Double? {
        val altitude = trustedGpsAltitude(
            provider = location.provider,
            hasAltitude = location.hasAltitude(),
            altitudeMeters = location.altitude,
        ) ?: return null
        return altitude.takeIf {
            canReuseGpsAltitude(nowMs, location.time, distanceMeters = 0f)
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
        if (intent?.action == ACTION_SET_UPDATE_FREQUENCY) {
            val frequency = GpsUpdateFrequency.fromSeconds(
                intent.getLongExtra(EXTRA_UPDATE_FREQUENCY_SECONDS, GpsUpdateFrequency.DEFAULT_SECONDS),
            )
            preferences.edit()
                .putLong(GpsUpdateFrequency.PREFERENCE_KEY, frequency.seconds)
                .apply()
            // Replace only the phone-location subscription and re-anchor the ticker. The
            // established camera BLE session remains untouched.
            if (enabled && cameraReady) restartLocationPipeline()
            return START_STICKY
        }
        if (intent?.action == ACTION_DISABLE) {
            stopGps()
            stopSelf()
            return START_NOT_STICKY
        }
        if (intent?.action == ACTION_ENABLE) {
            // An explicit tap is the only operation allowed to restart a failed pairing flow.
            awaitingPairingUserAction = false
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
        periodicGeoWriteJob?.cancel()
        periodicGeoWriteJob = null
        cameraVerified = false
        pairingConfirmationPending = false
        lastSentAt = 0L
        latestLocationDuringWrite = null
        latestLocation = null
        pendingAltitudeRefresh = false
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
        // A successful ID write completes the LE identity handshake. Location acquisition and
        // GEO delivery happen after the camera is already connected and must not keep the UI in
        // its connecting state.
        updateState(
            gpsStatusAfterCameraReady(wasReadyBeforeReconnect),
            name,
            null,
        )
        restartLocationPipeline()
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
            val altitudeRefreshLocation = latestLocationDuringWrite
                ?.takeIf { pendingAltitudeRefresh }
                ?.let(::Location)
            pendingAltitudeRefresh = false
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
            altitudeRefreshLocation?.let { latest ->
                serviceScope.launch {
                    delay(50L)
                    if (enabled && cameraReady) {
                        lastSentAt = 0L
                        maybeSend(latest, force = true)
                    }
                }
            }
            // Re-anchor the minute cadence at the successful write, so updates continue even
            // when LocationManager emits no further callbacks while stationary.
            startGeoWriteTicker()
            refreshNotification()
        } else {
            lastSentAt = 0L
            latestLocationDuringWrite = null
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
        periodicGeoWriteJob?.cancel()
        periodicGeoWriteJob = null
        stopLocationUpdates()
        // Force the first location after a reconnect to be sent again. The camera may have
        // dropped its GPS channel together with GATT even when the coordinates did not change.
        lastSentAt = 0L
        latestLocationDuringWrite = null
        pendingAltitudeRefresh = false
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
        periodicGeoWriteJob?.cancel()
        periodicGeoWriteJob = null
        stopLocationUpdates()
        cameraVerified = false
        preserveReadyDuringReconnect = false
        pairingConfirmationPending = false
        latestLocationDuringWrite = null
        pendingAltitudeRefresh = false
        geoWriteInFlight = false
        geoWriteTimeoutJob?.cancel()
        geoWriteTimeoutJob = null
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
        val pairingNeedsUserAction =
            message.contains("pairing", ignoreCase = true) ||
                message.contains("配对")
        if (pairingNeedsUserAction) {
            awaitingPairingUserAction = true
            // Close the current BLE/Classic flow before exposing the retry action. This prevents
            // a late bond callback from starting a second createBond() in the same attempt.
            bleClient.stop()
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
        if (enabled && !isPermissionError && !pairingNeedsUserAction &&
            !bluetoothOff && isBluetoothEnabled()
        ) {
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
        if (awaitingPairingUserAction) {
            updateState(GpsStatus.NEEDS_CAMERA, message = "请在相机上打开蓝牙配对")
            return
        }
        if (gpsRecoveryTarget(cameraReady, bleClient.isRunning()) == GpsRecoveryTarget.LOCATION_ONLY) {
            notificationOverride = null
            updateState(GpsStatus.WAITING_FIX, message = "正在获取手机位置")
            restartLocationPipeline()
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
        if (awaitingPairingUserAction) {
            GpsDiagnostics.record("BLE start skipped; pairing awaits explicit retry")
            return
        }
        if (bleClient.isRunning()) {
            GpsDiagnostics.record("BLE start skipped; attempt already active")
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
        // A BLE address without the complete Nikon identity is only a stale scan result, not a
        // pairing record. First-time flows must scan and pair instead of direct-connecting it.
        val savedBleAddress = preferences.getString(KEY_BLE_ADDRESS, null)
            .takeIf { hasCompleteIdentity }
        if (!preserveReadyDuringReconnect) {
            updateState(if (hasCompleteIdentity) GpsStatus.CONNECTING else GpsStatus.SEARCHING)
        }
        bleClient.start(
            controllerName = BuildConfig.GPS_CONTROLLER_NAME,
            savedDeviceId = savedId,
            savedNonce = savedNonce,
            savedBleAddress = savedBleAddress,
        )
    }

    private fun hasCompleteSavedIdentity(): Boolean =
        preferences.getLong(KEY_DEVICE_ID, Long.MIN_VALUE) != Long.MIN_VALUE &&
            preferences.getLong(KEY_NONCE, Long.MIN_VALUE) != Long.MIN_VALUE

    private fun startLocationUpdates(): Boolean {
        // A retry replaces any previous subscription. In particular, do this before permission
        // and provider checks so an error cannot leave an old high-frequency listener running.
        stopLocationUpdates()
        val fine = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (!fine && !coarse) {
            updateState(GpsStatus.ERROR, message = "需要定位权限")
            return false
        }
        val gpsEnabled = runCatching { locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER) }.getOrDefault(false)
        val networkEnabled = runCatching { locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER) }.getOrDefault(false)
        if (!gpsEnabled && !networkEnabled) {
            updateState(GpsStatus.ERROR, message = "请打开手机定位")
            return false
        }
        val frequency = configuredUpdateFrequency()
        return runCatching {
            if (gpsEnabled && locationManager.getProvider(LocationManager.GPS_PROVIDER) != null) {
                locationManager.requestLocationUpdates(
                    LocationManager.GPS_PROVIDER,
                    frequency.gpsSamplingIntervalMillis,
                    0f,
                    locationListener,
                    Looper.getMainLooper(),
                )
            }
            if (networkEnabled && locationManager.getProvider(LocationManager.NETWORK_PROVIDER) != null) {
                locationManager.requestLocationUpdates(
                    LocationManager.NETWORK_PROVIDER,
                    frequency.networkSamplingIntervalMillis,
                    0f,
                    locationListener,
                    Looper.getMainLooper(),
                )
            }
            GpsDiagnostics.record(
                "location sampling gps=${frequency.gpsSamplingIntervalMillis}ms " +
                    "network=${frequency.networkSamplingIntervalMillis}ms " +
                    "write=${frequency.intervalMillis}ms",
            )
            // Reuse a recent system fix immediately instead of waiting for the next provider
            // callback. This closes the small window where the user can shoot before the first
            // GPS payload reaches the camera.
            val now = System.currentTimeMillis()
            val cachedGps = if (gpsEnabled) {
                runCatching {
                    locationManager.getLastKnownLocation(LocationManager.GPS_PROVIDER)
                }.getOrNull()
            } else null
            val cachedNetwork = if (networkEnabled) {
                runCatching {
                    locationManager.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)
                }.getOrNull()
            } else null
            val recentCachedLocations = listOfNotNull(cachedGps, cachedNetwork).filter { location ->
                location.time > 0L && kotlin.math.abs(now - location.time) <= CACHED_LOCATION_MAX_AGE_MS
            }
            cachedGps?.let { gpsFix ->
                if (trustedAltitudeFix(gpsFix, now) != null) {
                    latestTrustedAltitudeFix = Location(gpsFix)
                }
            }
            val cached = recentCachedLocations.maxByOrNull { it.time }
            cached?.let(locationListener::onLocationChanged)
            true
        }.getOrElse {
            stopLocationUpdates()
            updateState(GpsStatus.ERROR, message = "无法获取定位")
            false
        }
    }

    private fun stopLocationUpdates() {
        runCatching { locationManager.removeUpdates(locationListener) }
    }

    private fun restartLocationPipeline() {
        periodicGeoWriteJob?.cancel()
        periodicGeoWriteJob = null
        if (startLocationUpdates()) startGeoWriteTicker()
    }

    private fun maybeSend(location: Location, force: Boolean = false) {
        if (!enabled) return
        if (geoWriteInFlight) {
            latestLocationDuringWrite = Location(location)
            if (force) pendingAltitudeRefresh = true
            return
        }
        val candidate = latestLocationDuringWrite ?: location
        if (!force && System.currentTimeMillis() - lastSentAt < configuredWriteIntervalMs()) {
            latestLocationDuringWrite = Location(candidate)
            return
        }
        latestLocationDuringWrite = null
        val trustedAltitude = resolveAltitude(candidate)
        if (trustedAltitude == null) {
            if (!altitudeUnavailableLogged) {
                GpsDiagnostics.record(
                    "GEO using fallback altitude=0 provider=${candidate.provider ?: "?"} " +
                        "hasAltitude=${candidate.hasAltitude()} rawAltitude=" +
                        (if (candidate.hasAltitude()) {
                            "%.1fm".format(Locale.US, candidate.altitude)
                        } else {
                            "none"
                        }) +
                        " verticalAccuracy=" +
                        (if (candidate.hasVerticalAccuracy()) {
                            "%.1fm".format(Locale.US, candidate.verticalAccuracyMeters)
                        } else {
                            "none"
                        }),
                )
                altitudeUnavailableLogged = true
            }
        } else {
            altitudeUnavailableLogged = false
        }
        // Coordinates are useful even when Android cannot provide a trustworthy altitude.
        // Write 0 m as the explicit fallback; the listener forces one immediate follow-up write
        // when a real GPS altitude later becomes available.
        val altitude = cameraAltitudeForWrite(trustedAltitude)
        val satellites = candidate.extras?.getInt("satellites", 0) ?: 0
        val payload = runCatching {
            GeoPayloadEncoder.encode(
                latitude = candidate.latitude,
                longitude = candidate.longitude,
                altitudeMeters = altitude,
                satellites = satellites,
                timestamp = Instant.now().toGeoUtcDateTime(),
            )
        }.getOrNull() ?: return
        geoWriteInFlight = true
        updateState(GpsStatus.WRITING)
        GpsDiagnostics.record(
            "GEO queued provider=${candidate.provider ?: "?"} " +
                "accuracy=${candidate.accuracy.toInt()}m altitude=" +
                "%.1fm".format(Locale.US, altitude),
        )
        bleClient.writeGeo(payload)
        geoWriteTimeoutJob?.cancel()
        geoWriteTimeoutJob = serviceScope.launch {
            delay(GEO_WRITE_TIMEOUT_MS)
            if (geoWriteInFlight && enabled) {
                geoWriteInFlight = false
                lastSentAt = 0L
                latestLocationDuringWrite = null
                onError("GPS write timeout")
            }
        }
    }

    /** Keep the configured GEO cadence independent from provider callbacks. */
    private fun startGeoWriteTicker() {
        periodicGeoWriteJob?.cancel()
        periodicGeoWriteJob = serviceScope.launch {
            while (isActive && enabled && cameraReady) {
                val intervalMs = configuredWriteIntervalMs()
                val elapsed = System.currentTimeMillis() - lastSentAt
                val waitMs = if (lastSentAt == 0L) intervalMs
                else (intervalMs - elapsed).coerceAtLeast(1_000L)
                delay(waitMs)
                if (!isActive || !enabled || !cameraReady) break
                latestLocation?.let(::maybeSend)
            }
        }
    }

    private fun configuredUpdateFrequency(): GpsUpdateFrequency = GpsUpdateFrequency.fromSeconds(
        preferences.getLong(GpsUpdateFrequency.PREFERENCE_KEY, GpsUpdateFrequency.DEFAULT_SECONDS),
    )

    private fun configuredWriteIntervalMs(): Long = configuredUpdateFrequency().intervalMillis

    private fun stopGps() {
        enabled = false
        awaitingPairingUserAction = false
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
        periodicGeoWriteJob?.cancel()
        periodicGeoWriteJob = null
        lastSentAt = 0L
        latestLocationDuringWrite = null
        latestLocation = null
        pendingAltitudeRefresh = false
        altitudeUnavailableLogged = false
        latestTrustedAltitudeFix = null
        stopLocationUpdates()
        if (::bleClient.isInitialized) bleClient.stop()
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
        periodicGeoWriteJob?.cancel()
        periodicGeoWriteJob = null
        lastSentAt = 0L
        latestLocationDuringWrite = null
        latestLocation = null
        pendingAltitudeRefresh = false
        altitudeUnavailableLogged = false
        latestTrustedAltitudeFix = null
        stopLocationUpdates()
        if (::bleClient.isInitialized) bleClient.stop()
        NikonGpsRuntime.state.update { it.copy(enabled = enabled, status = GpsStatus.AP_UNAVAILABLE, message = "AP 模式不可用") }
    }

    private fun updateState(
        status: GpsStatus,
        cameraName: String? = null,
        message: String? = null,
    ) {
        NikonGpsRuntime.state.update {
            it.copy(
                enabled = enabled,
                status = status,
                cameraName = cameraName ?: it.cameraName,
                message = message,
            )
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
        GpsStatus.PAIRING, GpsStatus.CAMERA_CONFIRM -> "正在连接相机"
        GpsStatus.PAIRING_SUCCESS, GpsStatus.CONNECTED -> "已连接，等待位置更新"
        GpsStatus.WRITING -> "已连接，正在写入位置"
        GpsStatus.WAITING_FIX -> "已连接，等待定位"
        GpsStatus.READY -> "已连接，自动写入位置"
        GpsStatus.AP_UNAVAILABLE -> "AP 模式不可用"
        GpsStatus.ERROR -> state.message ?: "GPS 连接失败"
    }

    private fun formatNotificationTime(timestamp: Long): String =
        java.text.SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(java.util.Date(timestamp))

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
        const val ACTION_SET_UPDATE_FREQUENCY = "com.ztransfer.gps.SET_UPDATE_FREQUENCY"
        const val EXTRA_UPDATE_FREQUENCY_SECONDS = "update_frequency_seconds"

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

        fun setUpdateFrequency(context: Context, frequency: GpsUpdateFrequency) {
            val intent = Intent(context, NikonGpsService::class.java)
                .setAction(ACTION_SET_UPDATE_FREQUENCY)
                .putExtra(EXTRA_UPDATE_FREQUENCY_SECONDS, frequency.seconds)
            context.startService(intent)
        }
    }
}
