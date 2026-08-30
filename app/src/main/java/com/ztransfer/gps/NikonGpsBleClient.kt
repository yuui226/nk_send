package com.ztransfer.gps

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.ParcelUuid
import java.util.Collections
import java.util.IdentityHashMap
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Small, single-threaded BLE client for Nikon Smart Device mode. */
@SuppressLint("MissingPermission")
internal class NikonGpsBleClient(
    private val context: Context,
    private val scope: CoroutineScope,
    private val listener: Listener,
) {
    interface Listener {
        fun onConnecting(name: String?)
        fun onBleAddress(address: String)
        fun onPairing()
        fun onReady(name: String, device: BluetoothDevice)
        fun onGeoWritten(success: Boolean)
        fun onPairedIdentity(device: Long, nonce: Long)
        fun onDisconnected()
        fun onNeedsPairing()
        fun onError(message: String)
    }

    private var scanner: BluetoothLeScanner? = null
    private var scanCallback: ScanCallback? = null
    private var scanTimeout: Job? = null
    private var gatt: BluetoothGatt? = null
    private var device: BluetoothDevice? = null
    private var pairChar: BluetoothGattCharacteristic? = null
    private var idChar: BluetoothGattCharacteristic? = null
    private var geoChar: BluetoothGattCharacteristic? = null
    private var descriptorQueue = ArrayDeque<BluetoothGattDescriptor>()
    private var stage1: GpsPairingPacket? = null
    private var stage3Sent = false
    private var idQueued = false
    private var controllerName = "ZTransfer"
    private var savedDeviceId: Long? = null
    private var savedNonce: Long? = null
    private var pendingGeo: ByteArray? = null
    private var ready = false
    private data class PendingWrite(val characteristic: BluetoothGattCharacteristic, val bytes: ByteArray)
    private val writeQueue = ArrayDeque<PendingWrite>()
    private var writeInFlight = false
    private var writeInFlightUuid: UUID? = null
    private var classicReceiver: BroadcastReceiver? = null
    private var classicTimeout: Job? = null
    private var classicPollJob: Job? = null
    private var classicBondReady = false
    private var classicTargetAddress: String? = null
    private var pendingRebondAddress: String? = null
    /** Address currently undergoing the one allowed createBond attempt. */
    private var classicBondAttemptAddress: String? = null
    private var pairingTimeout: Job? = null
    private var pairingNotified = false
    private var directConnectJob: Job? = null
    private var idWriteTimeout: Job? = null
    /** GATTs closed intentionally must not be reported as a camera disconnect. */
    private val suppressedDisconnects: MutableSet<BluetoothGatt> =
        Collections.synchronizedSet(Collections.newSetFromMap(IdentityHashMap()))

    fun start(
        controllerName: String = "ZTransfer",
        savedDeviceId: Long? = null,
        savedNonce: Long? = null,
        savedBleAddress: String? = null,
    ) {
        GpsDiagnostics.record("start savedIdentity=${savedDeviceId != null}")
        this.controllerName = controllerName
        this.savedDeviceId = savedDeviceId
        this.savedNonce = savedNonce
        directConnectJob?.cancel()
        directConnectJob = null
        idWriteTimeout?.cancel()
        idWriteTimeout = null
        if (gatt != null || scanCallback != null) return
        stage1 = null
        stage3Sent = false
        idQueued = false
        ready = false
        pairingNotified = false
        pairingTimeout?.cancel()
        pairingTimeout = null
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE)
            as? android.bluetooth.BluetoothManager
        scanner = manager?.adapter?.bluetoothLeScanner
        if (scanner == null) {
            listener.onError("Bluetooth unavailable")
            return
        }
        if (savedBleAddress != null) {
            val direct = runCatching { manager?.adapter?.getRemoteDevice(savedBleAddress) }.getOrNull()
            if (direct != null) {
                GpsDiagnostics.record("BLE direct connect address=$savedBleAddress")
                connect(direct)
                directConnectJob = scope.launch {
                    delay(DIRECT_CONNECT_TIMEOUT_MS)
                    if (gatt != null && scanCallback == null && !ready) {
                        GpsDiagnostics.record("BLE direct connect timeout; fallback scan")
                        directConnectJob = null
                        closeCurrentGatt(suppressCallback = true)
                        beginScan()
                    }
                }
                return
            }
        }
        beginScan()
    }

    fun stop() {
        scanTimeout?.cancel()
        scanTimeout = null
        directConnectJob?.cancel()
        directConnectJob = null
        idWriteTimeout?.cancel()
        idWriteTimeout = null
        scanCallback?.let { callback -> runCatching { scanner?.stopScan(callback) } }
        scanCallback = null
        closeCurrentGatt(suppressCallback = true)
        pairingTimeout?.cancel()
        pairingTimeout = null
        stopClassicPairing()
        device = null
        pendingGeo = null
        ready = false
    }

    fun writeGeo(bytes: ByteArray) {
        val gatt = gatt
        val characteristic = geoChar
        if (gatt == null || characteristic == null) {
            pendingGeo = bytes
            return
        }
        writeCharacteristic(gatt, characteristic, bytes)
    }

    private fun beginScan() {
        val scanner = scanner ?: return
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val record = result.scanRecord ?: return
                val hasService = record.serviceUuids?.any { it.uuid == SERVICE_UUID } == true
                if (!hasService) return
                scanCallback?.let { runCatching { scanner.stopScan(it) } }
                scanCallback = null
                scanTimeout?.cancel()
                device = result.device
                listener.onBleAddress(result.device.address)
                GpsDiagnostics.record("BLE found name=${result.device.name ?: record.deviceName ?: "?"}")
                listener.onConnecting(result.device.name ?: record.deviceName)
                connect(result.device)
            }

            override fun onScanFailed(errorCode: Int) {
                scanCallback = null
                GpsDiagnostics.record("BLE scan failed code=$errorCode")
                listener.onError("Bluetooth scan failed: $errorCode")
            }
        }
        scanCallback = callback
        try {
            scanner.startScan(
                listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_UUID)).build()),
                ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(),
                callback,
            )
            scanTimeout = scope.launch {
                delay(SCAN_TIMEOUT_MS)
                if (scanCallback === callback) {
                    runCatching { scanner.stopScan(callback) }
                    scanCallback = null
                    listener.onError("Camera not found")
                }
            }
        } catch (security: SecurityException) {
            scanCallback = null
            listener.onError("Bluetooth permission required")
        } catch (error: Exception) {
            scanCallback = null
            listener.onError(error.message ?: "Bluetooth scan failed")
        }
    }

    private fun connect(target: BluetoothDevice) {
        GpsDiagnostics.record("BLE connect address=${target.address}")
        try {
            val connection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                target.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
            } else {
                @Suppress("DEPRECATION")
                target.connectGatt(context, false, callback)
            }
            if (connection == null) {
                listener.onError("Bluetooth connection failed")
            } else {
                gatt = connection
            }
        } catch (security: SecurityException) {
            listener.onError("Bluetooth permission required")
        }
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            GpsDiagnostics.record("GATT state=$newState status=$status")
            if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                if (gatt !== g) {
                    suppressGattDisconnect(g)
                    runCatching { g.disconnect() }
                    runCatching { g.close() }
                    return
                }
                directConnectJob?.cancel()
                directConnectJob = null
                if (!g.requestMtu(517)) {
                    GpsDiagnostics.record("MTU request rejected; discovering services")
                    if (!g.discoverServices()) listener.onError("Camera service unavailable")
                }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                val wasSuppressed = suppressedDisconnects.remove(g)
                idWriteTimeout?.cancel()
                idWriteTimeout = null
                if (gatt === g) {
                    gatt = null
                    clearGattOperationState()
                    ready = false
                }
                runCatching { g.close() }
                if (wasSuppressed) return
                if (directConnectJob != null && !ready) {
                    directConnectJob?.cancel()
                    directConnectJob = null
                    beginScan()
                    return
                }
                listener.onDisconnected()
            } else if (status != BluetoothGatt.GATT_SUCCESS) {
                listener.onError("Bluetooth connection failed: $status")
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            if (gatt !== g) return
            if (!g.discoverServices()) listener.onError("Camera service unavailable")
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            if (gatt !== g) return
            GpsDiagnostics.record("GATT services status=$status")
            if (status != BluetoothGatt.GATT_SUCCESS) {
                listener.onError("Camera service unavailable")
                return
            }
            val service = g.getService(SERVICE_UUID)
            pairChar = service?.getCharacteristic(PAIR_UUID)
            idChar = service?.getCharacteristic(ID_UUID)
            geoChar = service?.getCharacteristic(GEO_UUID)
            val pair = pairChar
            val not1 = service?.getCharacteristic(NOT1_UUID)
            if (pair == null || not1 == null || idChar == null || geoChar == null) {
                listener.onError("Camera GPS service unavailable")
                return
            }
            val pairCccd = pair.getDescriptor(CCCD_UUID)
            val not1Cccd = not1.getDescriptor(CCCD_UUID)
            if (pairCccd == null || not1Cccd == null) {
                listener.onError("Camera GPS notification unavailable")
                return
            }
            descriptorQueue = ArrayDeque(listOf(pairCccd, not1Cccd))
            enableNextDescriptor(g)
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (gatt !== g) return
            if (status != BluetoothGatt.GATT_SUCCESS) {
                runCatching { g.disconnect() }
                listener.onError("Bluetooth setup failed")
                return
            }
            enableNextDescriptor(g)
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            if (gatt !== g) return
            handleCharacteristic(characteristic.uuid, value)
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (gatt !== g) return
            handleCharacteristic(characteristic.uuid, characteristic.value)
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            if (gatt !== g) return
            GpsDiagnostics.record("GATT write uuid=${characteristic.uuid} status=$status")
            writeInFlight = false
            writeInFlightUuid = null
            when (characteristic.uuid) {
                GEO_UUID -> listener.onGeoWritten(status == BluetoothGatt.GATT_SUCCESS)
                ID_UUID -> if (status == BluetoothGatt.GATT_SUCCESS) {
                    idWriteTimeout?.cancel()
                    idWriteTimeout = null
                    if (savedDeviceId == null) {
                        // Nikon exposes a different Classic address. Discover and bond it once;
                        // the next BLE connection will use the persisted stage-1 identity.
                        listener.onNeedsPairing()
                        startClassicPairing(device?.name)
                        closeGattForPairing()
                        if (classicBondReady) finishClassicPairing()
                    } else {
                        if (!ready) {
                            ready = true
                            listener.onReady(device?.name ?: "Nikon", device ?: return)
                        }
                        pendingGeo?.also { queued -> pendingGeo = null; writeCharacteristic(g, geoChar ?: return, queued) }
                    }
                } else listener.onError("Bluetooth write failed")
            }
            drainWrites(g)
        }
    }

    private fun enableNextDescriptor(g: BluetoothGatt) {
        val descriptor = descriptorQueue.removeFirstOrNull()
        if (descriptor == null) {
            val packet = NikonGpsPairingProtocol().newStage1(savedDeviceId, savedNonce)
            stage1 = packet
            if (savedDeviceId == null && !pairingNotified) {
                pairingNotified = true
                listener.onPairing()
            }
            pairingTimeout?.cancel()
            pairingTimeout = scope.launch {
                delay(7_000L)
                if (stage1 != null && !stage3Sent) {
                    GpsDiagnostics.record("pairing response timeout savedIdentity=${savedDeviceId != null}")
                    listener.onError(
                        if (savedDeviceId != null) "Camera pairing identity expired"
                        else "Camera pairing handshake timeout"
                    )
                }
            }
            writeCharacteristic(g, pairChar ?: return, packet.encode())
            return
        }
        val enabled = if (descriptor.characteristic.uuid == PAIR_UUID) {
            BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
        } else {
            BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        }
        if (!g.setCharacteristicNotification(descriptor.characteristic, true)) {
            listener.onError("Bluetooth setup failed")
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (g.writeDescriptor(descriptor, enabled) != BluetoothGatt.GATT_SUCCESS) {
                listener.onError("Bluetooth setup failed")
            }
        } else {
            @Suppress("DEPRECATION")
            descriptor.value = enabled
            @Suppress("DEPRECATION")
            if (!g.writeDescriptor(descriptor)) listener.onError("Bluetooth setup failed")
        }
    }

    private fun handleCharacteristic(uuid: UUID, value: ByteArray) {
        if (uuid == NOT1_UUID && value.contentEquals(byteArrayOf(0x01, 0x00))) {
            queueControllerIdIfNeeded()
            return
        }
        if (uuid != PAIR_UUID) return
        val packet = GpsPairingPacket.decode(value) ?: return
        val first = stage1 ?: return
        if (packet.stage == 2 && !stage3Sent) {
            if (savedDeviceId == null && !pairingNotified) {
                pairingNotified = true
                listener.onPairing()
            }
            pairingTimeout?.cancel()
            pairingTimeout = null
            val response = NikonGpsPairingProtocol().stage3For(first, packet)
            if (response == null) {
                GpsDiagnostics.record("pairing stage2 salt rejected")
                listener.onError("Camera pairing rejected")
                return
            }
            stage3Sent = true
            GpsDiagnostics.record("pairing stage3 sent")
            writeCharacteristic(gatt ?: return, pairChar ?: return, response.encode())
            pairingTimeout = scope.launch {
                delay(7_000L)
                if (!idQueued) {
                    GpsDiagnostics.record("pairing stage4 timeout")
                    listener.onError("Camera pairing handshake timeout")
                }
            }
        } else if (packet.stage == 4) {
            pairingTimeout?.cancel()
            pairingTimeout = null
            GpsDiagnostics.record("pairing stage4 received")
            scope.launch {
                delay(1_500)
                queueControllerIdIfNeeded()
            }
        }
    }

    private fun queueControllerIdIfNeeded() {
        if (idQueued || idChar == null || gatt == null) return
        pairingTimeout?.cancel()
        pairingTimeout = null
        idQueued = true
        GpsDiagnostics.record("ID queued")
        val bytes = controllerName.toByteArray(Charsets.US_ASCII).copyOf(32)
        writeCharacteristic(gatt ?: return, idChar ?: return, bytes)
    }

    private fun closeGattForPairing() {
        closeCurrentGatt(suppressCallback = true)
    }

    private fun startClassicPairing(bleName: String?) {
        if (classicReceiver != null) return
        val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? android.bluetooth.BluetoothManager)?.adapter
        if (adapter == null || !adapter.isEnabled) {
            listener.onError("Bluetooth unavailable")
            return
        }
        classicTimeout?.cancel()
        classicPollJob?.cancel()
        classicReceiver?.let { runCatching { context.unregisterReceiver(it) } }
        val targetName = bleName?.takeIf { it.isNotBlank() } ?: "Nikon"
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    BluetoothDevice.ACTION_PAIRING_REQUEST -> {
                        val pairingDevice = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                        } else {
                            @Suppress("DEPRECATION") intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                        } ?: return
                        val pairingName = intent.getStringExtra(BluetoothDevice.EXTRA_NAME)
                            ?: runCatching { pairingDevice.name }.getOrNull()
                        if (!matchesClassicDevice(pairingDevice, pairingName, targetName)) return
                        val pairingAddress = pairingDevice.address
                        if (pairingAddress != classicTargetAddress &&
                            pairingAddress != classicBondAttemptAddress
                        ) return
                        val variant = intent.getIntExtra(
                            BluetoothDevice.EXTRA_PAIRING_VARIANT,
                            -1,
                        )
                        GpsDiagnostics.record("Classic pairing request variant=$variant")
                        // Nikon's Classic leg uses SSP confirmation: the camera shows the
                        // code and the user confirms it on-camera. Confirm the phone side
                        // silently so Android does not show a competing system dialog.
                        if (variant == BluetoothDevice.PAIRING_VARIANT_PASSKEY_CONFIRMATION) {
                            val confirmed = runCatching { pairingDevice.setPairingConfirmation(true) }
                                .getOrDefault(false)
                            GpsDiagnostics.record("Classic pairing confirmation=$confirmed")
                            // setPairingConfirmation is privileged on many Android builds. Do
                            // not abort the ordered request when the call failed; otherwise the
                            // phone leaves bonding stuck instead of showing the normal prompt.
                            if (confirmed) runCatching { abortBroadcast() }
                        }
                    }
                    BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> {
                        // Classic discovery commonly ends before Nikon becomes visible. Keep
                        // cycling discovery during the short pairing window instead of failing
                        // after the first scan pass.
                        val currentReceiver = this
                        if (classicReceiver === currentReceiver) {
                            scope.launch {
                                delay(700L)
                                if (classicReceiver === currentReceiver && !adapter.isDiscovering) {
                                    runCatching { adapter.startDiscovery() }
                                }
                            }
                        }
                    }
                    BluetoothDevice.ACTION_FOUND -> {
                        val found = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                        } else {
                            @Suppress("DEPRECATION") intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                        } ?: return
                        val foundName = intent.getStringExtra(BluetoothDevice.EXTRA_NAME) ?: runCatching { found.name }.getOrNull()
                        if (!matchesClassicDevice(found, foundName, targetName)) return
                        classicTargetAddress = found.address
                        GpsDiagnostics.record("Classic found name=${foundName ?: "?"} bonded=${found.bondState == BluetoothDevice.BOND_BONDED}")
                        runCatching { adapter.cancelDiscovery() }
                        if (found.bondState == BluetoothDevice.BOND_BONDED && savedDeviceId == null) {
                            // A camera can forget its Nikon pairing record while Android keeps
                            // the old Classic bond. Treat that bond as stale in a fresh flow so
                            // Android and the camera show the pairing-code confirmation again.
                            if (found.address == classicBondAttemptAddress) {
                                classicBondReady = true
                                if (idQueued) finishClassicPairing()
                            } else if (classicBondAttemptAddress == null) {
                                requestFreshClassicPairing(found)
                            }
                        } else if (found.bondState == BluetoothDevice.BOND_BONDED) {
                            classicBondReady = true
                            if (idQueued) finishClassicPairing()
                        } else if (found.bondState == BluetoothDevice.BOND_NONE) {
                            startClassicBond(found)
                        }
                    }
                    BluetoothDevice.ACTION_BOND_STATE_CHANGED -> {
                        val found = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                        } else {
                            @Suppress("DEPRECATION") intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                        }
                        if (found == null) return
                        val relevantAddress = found.address == pendingRebondAddress ||
                            found.address == classicTargetAddress ||
                            found.address == classicBondAttemptAddress
                        if (!relevantAddress) return
                        if (found?.bondState == BluetoothDevice.BOND_NONE &&
                            found.address == pendingRebondAddress
                        ) {
                            // The stale bond is gone. Recreate the bond exactly once for this
                            // same Classic address; polling remains guarded by pendingRebondAddress.
                            GpsDiagnostics.record("Classic stale bond removed address=${found.address}; recreating once")
                            val currentReceiver = this
                            scope.launch {
                                delay(350L)
                                if (classicReceiver == currentReceiver &&
                                    pendingRebondAddress == found.address &&
                                    classicBondAttemptAddress == null
                                ) {
                                    startClassicBond(found)
                                }
                            }
                        } else if (found?.bondState == BluetoothDevice.BOND_BONDED) {
                            if (savedDeviceId == null && found.address != classicBondAttemptAddress) return
                            if (found.address == pendingRebondAddress) pendingRebondAddress = null
                            classicBondAttemptAddress = null
                            classicBondReady = true
                            if (idQueued) finishClassicPairing()
                        } else if (found?.bondState == BluetoothDevice.BOND_NONE &&
                            found.address == classicBondAttemptAddress
                        ) {
                            classicBondAttemptAddress = null
                            stopClassicPairing()
                            listener.onError("请确认蓝牙配对")
                        }
                    }
                }
            }
        }
        classicReceiver = receiver
        classicBondReady = false
        classicTargetAddress = null
        classicBondAttemptAddress = null
        runCatching {
            val filter = IntentFilter().apply {
                addAction(BluetoothDevice.ACTION_FOUND)
                addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
                addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
                addAction(BluetoothDevice.ACTION_PAIRING_REQUEST)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                context.registerReceiver(receiver, filter)
            }
        }.onFailure {
            classicReceiver = null
            listener.onError("请确认蓝牙配对")
            return
        }
        val discoveryStarted = runCatching { adapter.startDiscovery() }.getOrDefault(false)
        GpsDiagnostics.record("Classic discovery started=$discoveryStarted")
        if (!discoveryStarted) {
            scope.launch {
                delay(700L)
                if (classicReceiver === receiver && !adapter.isDiscovering) {
                    runCatching { adapter.startDiscovery() }
                }
            }
        }
        classicPollJob = scope.launch {
            repeat(30) {
                delay(1_000L)
                if (classicReceiver !== receiver) return@launch
                val bonded = runCatching {
                    adapter.bondedDevices.firstOrNull { candidate ->
                        matchesClassicDevice(candidate, candidate.name, targetName)
                    }
                }.getOrNull()
                if (bonded != null && savedDeviceId == null) {
                    // A bond created by our current attempt is the one we are waiting for;
                    // never remove it as "stale" on the next polling tick.
                    if (bonded.address == classicBondAttemptAddress) {
                        classicBondReady = true
                        GpsDiagnostics.record("Classic bond observed by polling name=${bonded.name ?: "?"}")
                        if (idQueued) {
                            finishClassicPairing()
                            return@launch
                        }
                    } else if (classicBondAttemptAddress == null) {
                        classicTargetAddress = bonded.address
                        requestFreshClassicPairing(bonded)
                    }
                } else if (bonded != null) {
                    pendingRebondAddress = null
                    classicTargetAddress = bonded.address
                    classicBondReady = true
                    GpsDiagnostics.record("Classic bond observed by polling name=${bonded.name ?: "?"}")
                    if (idQueued) {
                        finishClassicPairing()
                        return@launch
                    }
                }
            }
        }
        classicTimeout = scope.launch {
            delay(30_000)
            if (classicReceiver === receiver) {
                stopClassicPairing()
                listener.onError("请确认蓝牙配对")
            }
        }
    }

    private fun finishClassicPairing() {
        if (classicReceiver == null) return
        stage1?.let { listener.onPairedIdentity(it.device, it.nonce) }
        stopClassicPairing()
        GpsDiagnostics.record("Classic pairing complete; reconnecting BLE")
        listener.onDisconnected()
    }

    private fun stopClassicPairing() {
        val wasActive = classicReceiver != null
        classicTimeout?.cancel()
        classicTimeout = null
        classicPollJob?.cancel()
        classicPollJob = null
        classicReceiver?.let { runCatching { context.unregisterReceiver(it) } }
        classicReceiver = null
        classicBondReady = false
        classicTargetAddress = null
        pendingRebondAddress = null
        classicBondAttemptAddress = null
        val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? android.bluetooth.BluetoothManager)?.adapter
        if (wasActive && adapter?.isDiscovering == true) runCatching { adapter.cancelDiscovery() }
    }

    private fun closeCurrentGatt(suppressCallback: Boolean) {
        val current = gatt ?: return
        if (suppressCallback) suppressGattDisconnect(current)
        gatt = null
        clearGattOperationState()
        ready = false
        runCatching { current.disconnect() }
        runCatching { current.close() }
    }

    private fun suppressGattDisconnect(target: BluetoothGatt) {
        suppressedDisconnects.add(target)
        scope.launch {
            delay(10_000L)
            suppressedDisconnects.remove(target)
        }
    }

    private fun clearGattOperationState() {
        pairChar = null
        idChar = null
        geoChar = null
        descriptorQueue.clear()
        writeQueue.clear()
        writeInFlight = false
        writeInFlightUuid = null
    }

    private fun requestFreshClassicPairing(found: BluetoothDevice) {
        if (pendingRebondAddress == found.address) return
        classicTargetAddress = found.address
        pendingRebondAddress = found.address
        classicBondReady = false
        val removed = runCatching {
            val method = BluetoothDevice::class.java.getMethod("removeBond")
            method.invoke(found) as? Boolean ?: false
        }.getOrDefault(false)
        GpsDiagnostics.record("Classic stale bond remove=$removed address=${found.address}")
        if (!removed) {
            stopClassicPairing()
            listener.onError("请在系统蓝牙中删除相机配对后重试")
        }
    }

    /** Start at most one user-mediated Classic pairing attempt for the discovered address. */
    private fun startClassicBond(found: BluetoothDevice) {
        if (classicBondAttemptAddress != null) return
        classicTargetAddress = found.address
        classicBondAttemptAddress = found.address
        val started = runCatching { found.createBond() }.getOrDefault(false)
        GpsDiagnostics.record("Classic createBond=$started address=${found.address}")
        if (!started) {
            classicBondAttemptAddress = null
            stopClassicPairing()
            listener.onError("请确认蓝牙配对")
        }
    }

    private fun matchesClassicDevice(
        candidate: BluetoothDevice,
        candidateName: String?,
        targetName: String,
    ): Boolean = candidate.address == classicTargetAddress ||
        candidate.address == device?.address ||
        namesMatch(candidateName, targetName) ||
        (targetName.equals("Nikon", ignoreCase = true) &&
            candidateName?.contains("Nikon", ignoreCase = true) == true)

    private fun namesMatch(foundName: String?, targetName: String?): Boolean {
        if (foundName.isNullOrBlank() || targetName.isNullOrBlank()) return false
        val found = foundName.trim().lowercase(Locale.ROOT)
        val target = targetName.trim().lowercase(Locale.ROOT)
        val shorter = if (found.length <= target.length) found else target
        val longer = if (found.length <= target.length) target else found
        return found == target || (shorter.length >= 4 && longer.startsWith(shorter))
    }

    private fun writeCharacteristic(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, bytes: ByteArray) {
        writeQueue.addLast(PendingWrite(characteristic, bytes.copyOf()))
        drainWrites(g)
    }

    private fun drainWrites(g: BluetoothGatt) {
        if (writeInFlight) return
        val next = writeQueue.removeFirstOrNull() ?: return
        writeInFlight = true
        writeInFlightUuid = next.characteristic.uuid
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val result = g.writeCharacteristic(next.characteristic, next.bytes, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
                if (result != BluetoothGatt.GATT_SUCCESS) {
                    writeInFlight = false
                    writeInFlightUuid = null
                    onWriteRejected(next.characteristic)
                    drainWrites(g)
                } else {
                    scheduleIdWriteTimeoutIfNeeded(g, next.characteristic)
                }
            } else {
                @Suppress("DEPRECATION")
                next.characteristic.value = next.bytes
                @Suppress("DEPRECATION")
                if (!g.writeCharacteristic(next.characteristic)) {
                    writeInFlight = false
                    writeInFlightUuid = null
                    onWriteRejected(next.characteristic)
                    drainWrites(g)
                } else {
                    scheduleIdWriteTimeoutIfNeeded(g, next.characteristic)
                }
            }
        } catch (security: SecurityException) {
            writeInFlight = false
            writeInFlightUuid = null
            listener.onError("Bluetooth permission required")
            drainWrites(g)
        }
    }

    private fun scheduleIdWriteTimeoutIfNeeded(
        expectedGatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
    ) {
        if (savedDeviceId == null || characteristic.uuid != ID_UUID) return
        idWriteTimeout?.cancel()
        idWriteTimeout = scope.launch {
            delay(3_000L)
            val currentDevice = device
            if (!ready && gatt === expectedGatt && currentDevice != null &&
                writeInFlightUuid == ID_UUID
            ) {
                // A missing ID callback is not proof that the camera accepted the connection.
                // Do not bypass this gate: doing so can report success while the camera is still
                // waiting for pairing confirmation. Let the service retry from a clean GATT.
                GpsDiagnostics.record("ID write callback timeout; confirmation required")
                writeInFlight = false
                writeInFlightUuid = null
                pendingGeo = null
                listener.onError("GPS connection confirmation timeout")
            }
        }
    }

    private fun onWriteRejected(characteristic: BluetoothGattCharacteristic) {
        if (characteristic.uuid == GEO_UUID) listener.onGeoWritten(false)
        else if (characteristic.uuid == ID_UUID) {
            idWriteTimeout?.cancel()
            idWriteTimeout = null
            listener.onError("Bluetooth write failed")
        }
    }

    companion object {
        private const val SCAN_TIMEOUT_MS = 15_000L
        private const val DIRECT_CONNECT_TIMEOUT_MS = 4_500L
        val SERVICE_UUID = UUID.fromString("0000de00-3dd4-4255-8d62-6dc7b9bd5561")
        val PAIR_UUID = UUID.fromString("00002000-3dd4-4255-8d62-6dc7b9bd5561")
        val NOT1_UUID = UUID.fromString("00002008-3dd4-4255-8d62-6dc7b9bd5561")
        val ID_UUID = UUID.fromString("00002002-3dd4-4255-8d62-6dc7b9bd5561")
        val GEO_UUID = UUID.fromString("00002007-3dd4-4255-8d62-6dc7b9bd5561")
        val CCCD_UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
