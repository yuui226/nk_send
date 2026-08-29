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
    private var not1Received = false
    private var idQueued = false
    private var controllerName = "ZTransfer"
    private var savedDeviceId: Long? = null
    private var savedNonce: Long? = null
    private var pendingGeo: ByteArray? = null
    private var ready = false
    private data class PendingWrite(val characteristic: BluetoothGattCharacteristic, val bytes: ByteArray)
    private val writeQueue = ArrayDeque<PendingWrite>()
    private var writeInFlight = false
    private var classicReceiver: BroadcastReceiver? = null
    private var classicTimeout: Job? = null
    private var classicBondReady = false
    private var suppressDisconnect = false

    fun start(
        controllerName: String = "ZTransfer",
        savedDeviceId: Long? = null,
        savedNonce: Long? = null,
    ) {
        this.controllerName = controllerName
        this.savedDeviceId = savedDeviceId
        this.savedNonce = savedNonce
        if (gatt != null || scanCallback != null) return
        stage1 = null
        stage3Sent = false
        not1Received = false
        idQueued = false
        ready = false
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE)
            as? android.bluetooth.BluetoothManager
        scanner = manager?.adapter?.bluetoothLeScanner
        if (scanner == null) {
            listener.onError("Bluetooth unavailable")
            return
        }
        beginScan()
    }

    fun stop() {
        scanTimeout?.cancel()
        scanTimeout = null
        scanCallback?.let { callback -> runCatching { scanner?.stopScan(callback) } }
        scanCallback = null
        gatt?.disconnect()
        gatt?.close()
        classicTimeout?.cancel()
        classicTimeout = null
        classicReceiver?.let { runCatching { context.unregisterReceiver(it) } }
        classicReceiver = null
        classicBondReady = false
        suppressDisconnect = false
        gatt = null
        device = null
        pairChar = null
        idChar = null
        geoChar = null
        pendingGeo = null
        ready = false
        writeQueue.clear()
        writeInFlight = false
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
                listener.onConnecting(result.device.name ?: record.deviceName)
                connect(result.device)
            }

            override fun onScanFailed(errorCode: Int) {
                scanCallback = null
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
        try {
            gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                target.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
            } else {
                @Suppress("DEPRECATION")
                target.connectGatt(context, false, callback)
            }
        } catch (security: SecurityException) {
            listener.onError("Bluetooth permission required")
        }
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                g.requestMtu(517)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (gatt === g) {
                    gatt = null
                    pairChar = null
                    idChar = null
                    geoChar = null
                    descriptorQueue.clear()
                    writeQueue.clear()
                    writeInFlight = false
                    ready = false
                }
                runCatching { g.close() }
                if (suppressDisconnect) {
                    suppressDisconnect = false
                    return
                }
                listener.onDisconnected()
            } else if (status != BluetoothGatt.GATT_SUCCESS) {
                listener.onError("Bluetooth connection failed: $status")
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            g.discoverServices()
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
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
            descriptorQueue = ArrayDeque(listOfNotNull(pair.getDescriptor(CCCD_UUID), not1.getDescriptor(CCCD_UUID)))
            enableNextDescriptor(g)
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                runCatching { g.disconnect() }
                listener.onError("Bluetooth setup failed")
                return
            }
            enableNextDescriptor(g)
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            handleCharacteristic(characteristic.uuid, value)
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            handleCharacteristic(characteristic.uuid, characteristic.value)
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            writeInFlight = false
            when (characteristic.uuid) {
                GEO_UUID -> listener.onGeoWritten(status == BluetoothGatt.GATT_SUCCESS)
                ID_UUID -> if (status == BluetoothGatt.GATT_SUCCESS) {
                    stage1?.let { listener.onPairedIdentity(it.device, it.nonce) }
                    if (savedDeviceId == null) {
                        // Nikon exposes a different Classic address. Discover and bond it once;
                        // the next BLE connection will use the persisted stage-1 identity.
                        listener.onNeedsPairing()
                        startClassicPairing(device?.name)
                        closeGattForPairing()
                        if (classicBondReady) finishClassicPairing()
                    } else {
                        ready = true
                        listener.onReady(device?.name ?: "Nikon", device ?: return)
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
            if (savedDeviceId == null && classicReceiver == null) {
                // Start discovery before the BLE handshake completes. Nikon cameras often only
                // expose their Classic endpoint briefly while Smart Device pairing is active.
                startClassicPairing(device?.name)
            }
            writeCharacteristic(g, pairChar ?: return, packet.encode())
            return
        }
        val enabled = if (descriptor.characteristic.uuid == PAIR_UUID) {
            BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
        } else {
            BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        }
        g.setCharacteristicNotification(descriptor.characteristic, true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeDescriptor(descriptor, enabled)
        } else {
            @Suppress("DEPRECATION")
            descriptor.value = enabled
            @Suppress("DEPRECATION")
            g.writeDescriptor(descriptor)
        }
    }

    private fun handleCharacteristic(uuid: UUID, value: ByteArray) {
        if (uuid == NOT1_UUID && value.contentEquals(byteArrayOf(0x01, 0x00))) {
            not1Received = true
            queueControllerIdIfNeeded()
            return
        }
        if (uuid != PAIR_UUID) return
        val packet = GpsPairingPacket.decode(value) ?: return
        val first = stage1 ?: return
        if (packet.stage == 2 && !stage3Sent) {
            val response = NikonGpsPairingProtocol().stage3For(first, packet)
            if (response == null) {
                listener.onError("Camera pairing rejected")
                return
            }
            stage3Sent = true
            writeCharacteristic(gatt ?: return, pairChar ?: return, response.encode())
        } else if (packet.stage == 4) {
            scope.launch {
                delay(1_500)
                queueControllerIdIfNeeded()
            }
        }
    }

    private fun queueControllerIdIfNeeded() {
        if (idQueued || idChar == null || gatt == null) return
        idQueued = true
        val bytes = controllerName.toByteArray(Charsets.US_ASCII).copyOf(32)
        writeCharacteristic(gatt ?: return, idChar ?: return, bytes)
    }

    private fun closeGattForPairing() {
        val current = gatt ?: return
        suppressDisconnect = true
        gatt = null
        pairChar = null
        idChar = null
        geoChar = null
        writeQueue.clear()
        writeInFlight = false
        runCatching { current.disconnect() }
        runCatching { current.close() }
    }

    private fun startClassicPairing(bleName: String?) {
        if (classicReceiver != null) return
        val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? android.bluetooth.BluetoothManager)?.adapter
        if (adapter == null || !adapter.isEnabled) {
            listener.onError("Bluetooth unavailable")
            return
        }
        classicTimeout?.cancel()
        classicReceiver?.let { runCatching { context.unregisterReceiver(it) } }
        val targetName = bleName?.takeIf { it.isNotBlank() } ?: "Nikon"
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
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
                        val matches = found.address == device?.address ||
                            namesMatch(foundName, targetName) ||
                            foundName?.contains("Nikon", ignoreCase = true) == true
                        if (!matches) return
                        runCatching { adapter.cancelDiscovery() }
                        if (found.bondState == BluetoothDevice.BOND_BONDED) {
                            classicBondReady = true
                            if (idQueued) finishClassicPairing()
                        } else if (found.bondState == BluetoothDevice.BOND_NONE) {
                            val started = runCatching { found.createBond() }.getOrDefault(false)
                            if (!started) {
                                listener.onError("请确认蓝牙配对")
                            }
                        }
                    }
                    BluetoothDevice.ACTION_BOND_STATE_CHANGED -> {
                        val found = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                        } else {
                            @Suppress("DEPRECATION") intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                        }
                        if (found?.bondState == BluetoothDevice.BOND_BONDED) {
                            classicBondReady = true
                            if (idQueued) finishClassicPairing()
                        }
                    }
                }
            }
        }
        classicReceiver = receiver
        classicBondReady = false
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
        runCatching { adapter.startDiscovery() }.onFailure { listener.onError("请确认蓝牙配对") }
        classicTimeout = scope.launch {
            delay(30_000)
            if (classicReceiver === receiver) {
                finishClassicPairing()
                listener.onError("请确认蓝牙配对")
            }
        }
    }

    private fun finishClassicPairing() {
        classicTimeout?.cancel()
        classicTimeout = null
        classicReceiver?.let { runCatching { context.unregisterReceiver(it) } }
        classicReceiver = null
        classicBondReady = false
        listener.onDisconnected()
    }

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
            try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val result = g.writeCharacteristic(next.characteristic, next.bytes, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
                if (result != BluetoothGatt.GATT_SUCCESS) {
                    writeInFlight = false
                    onWriteRejected(next.characteristic)
                    drainWrites(g)
                }
            } else {
                @Suppress("DEPRECATION")
                next.characteristic.value = next.bytes
                @Suppress("DEPRECATION")
                if (!g.writeCharacteristic(next.characteristic)) {
                    writeInFlight = false
                    onWriteRejected(next.characteristic)
                    drainWrites(g)
                }
            }
        } catch (security: SecurityException) {
            writeInFlight = false
            listener.onError("Bluetooth permission required")
            drainWrites(g)
        }
    }

    private fun onWriteRejected(characteristic: BluetoothGattCharacteristic) {
        if (characteristic.uuid == GEO_UUID) listener.onGeoWritten(false)
        else if (characteristic.uuid == ID_UUID) listener.onError("Bluetooth write failed")
    }

    companion object {
        private const val SCAN_TIMEOUT_MS = 15_000L
        val SERVICE_UUID = UUID.fromString("0000de00-3dd4-4255-8d62-6dc7b9bd5561")
        val PAIR_UUID = UUID.fromString("00002000-3dd4-4255-8d62-6dc7b9bd5561")
        val NOT1_UUID = UUID.fromString("00002008-3dd4-4255-8d62-6dc7b9bd5561")
        val ID_UUID = UUID.fromString("00002002-3dd4-4255-8d62-6dc7b9bd5561")
        val GEO_UUID = UUID.fromString("00002007-3dd4-4255-8d62-6dc7b9bd5561")
        val CCCD_UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
