package com.ztransfer.gps

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import com.ztransfer.BuildConfig
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

internal data class BleControlProbeState(
    val busy: Boolean = false,
    val connected: Boolean = false,
    val canTestMenu: Boolean = false,
    val canVerifyMenu: Boolean = false,
    val canNavigate: Boolean = false,
    val remoteActive: Boolean = false,
    val summary: String = "请先关闭 GPS 和相机 Wi-Fi 连接，再读取能力",
    val log: String = "",
)

/** Debug-only, foreground-only probe. Never sends an AP/STA request or edits pairing data. */
@SuppressLint("MissingPermission")
internal class NikonBleControlProbe(context: Context, private val scope: CoroutineScope) {
    private val context = context.applicationContext
    private val logPreferences = this.context.getSharedPreferences("ble_control_probe_debug", Context.MODE_PRIVATE)
    private val mutableState = MutableStateFlow(BleControlProbeState(log = logPreferences.getString("last_log", "").orEmpty()))
    val state: StateFlow<BleControlProbeState> = mutableState.asStateFlow()
    private val entries = ArrayDeque<String>()
    private var client: NikonGpsBleClient? = null
    private var gatt: BluetoothGatt? = null
    private var job: Job? = null
    private var idleJob: Job? = null
    private var generation = 0
    private var expectedRead: UUID? = null
    private var readReply: CompletableDeferred<Pair<Int, ByteArray>>? = null
    private var expectedDescriptor: UUID? = null
    private var descriptorReply: CompletableDeferred<Int>? = null
    private var writeReply: CompletableDeferred<Int>? = null
    private var expectedOpcode: Int? = null
    private var controlReply: CompletableDeferred<ControlProbeResponse>? = null
    private var remoteRequested = false
    private var selectorSupported = false
    private var pressedKey: Int? = null

    fun readCapabilities() {
        if (state.value.busy) return
        stop()
        entries.clear()
        mutableState.value = BleControlProbeState(busy = true, summary = "正在连接蓝牙")
        record("BLE control probe v3 app=${BuildConfig.VERSION_NAME}(${BuildConfig.VERSION_CODE}) Android=${Build.VERSION.SDK_INT}")
        record("Initial phase: capability reads only; no network-mode, pairing-reset or location writes")
        val token = generation
        job = scope.launch {
            try {
                check(!NikonGpsRuntime.state.value.enabled && !NikonGpsRuntime.wifiWakeState.value.isBusy) { "请先关闭 GPS，等待热点唤醒结束" }
                val prefs = context.getSharedPreferences("nikon_gps", Context.MODE_PRIVATE)
                check(!prefs.getBoolean("enabled", false)) { "请先关闭 GPS" }
                val identity = prefs.getLong("device_id", Long.MIN_VALUE)
                val nonce = prefs.getLong("nonce", Long.MIN_VALUE)
                val address = prefs.getString("ble_address", null)
                check(identity != Long.MIN_VALUE && nonce != Long.MIN_VALUE && address != null) { "请先用本 Debug 包的 GPS 功能配对相机，再关闭 GPS" }
                check(Build.VERSION.SDK_INT < 31 || ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED) { "需要蓝牙权限" }
                check(context.getSystemService(BluetoothManager::class.java)?.adapter?.isEnabled == true) { "请开启手机蓝牙" }
                val connected = CompletableDeferred<BluetoothGatt>()
                val probeClient = NikonGpsBleClient(context, scope, listener(token, connected))
                client = probeClient
                probeClient.start(BuildConfig.GPS_CONTROLLER_NAME, identity, nonce, address, wifiOnly = true)
                gatt = withTimeout(30_000) { connected.await() }
                mutableState.value = state.value.copy(connected = true, summary = "正在读取能力")
                val current = requireNotNull(gatt)
                for (service in current.services) {
                    if (service.uuid == NikonGpsBleClient.SERVICE_UUID || service.uuid == DEVICE_INFO) {
                        for (ch in service.characteristics) record("GATT ${ch.uuid} props=0x${ch.properties.toString(16)}")
                    }
                }
                for (uuid in listOf(MODEL, FIRMWARE, POWER, FEATURE, STATUS)) {
                    val ch = find(uuid)
                    if (ch == null || ch.properties and BluetoothGattCharacteristic.PROPERTY_READ == 0) {
                        record("READ $uuid unavailable")
                        continue
                    }
                    val (status, bytes) = read(ch)
                    // SSID/password, pairing identity and serial number are deliberately omitted.
                    val value = if (uuid == MODEL || uuid == FIRMWARE) bytes.toString(Charsets.UTF_8).trimEnd('\u0000') else bytes.hex()
                    record("READ $uuid status=$status data=$value")
                    if (uuid == STATUS && status == 0) record(BleControlProbeProtocol.describeStatus(bytes))
                }
                val control = find(CONTROL)
                if (control == null || control.properties and BluetoothGattCharacteristic.PROPERTY_WRITE == 0) {
                    finishUnsupported("相机未提供蓝牙菜单控制接口")
                    return@launch
                }
                enableUpdates(control)
                find(STATUS)?.let { if (it.properties and (BluetoothGattCharacteristic.PROPERTY_INDICATE or BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0) enableUpdates(it) }
                // Official clients query control capabilities after entering remote mode. Do not
                // turn a pre-session rejection into a false "unsupported" result or a dead end.
                // Entering that mode is left to the user's explicit Test Menu action below.
                mutableState.value = state.value.copy(
                    busy = false,
                    canTestMenu = true,
                    summary = "接口读取完成，可测试菜单",
                )
                record("Interface reads complete. Menu capabilities require an explicit remote session; STA not verified")
                saveLog()
                armIdleTimeout()
            } catch (cancelled: CancellationException) {
                if (token == generation) fail("读取超时或已取消")
            } catch (error: Exception) {
                if (token == generation) fail(error.message ?: "蓝牙读取失败")
            } finally {
                if (token == generation) job = null
            }
        }
    }

    fun testMenu() {
        if (!state.value.canTestMenu || state.value.busy || !state.value.connected) return
        runOperation("正在测试菜单") {
            if (!remoteRequested) {
                remoteRequested = true // Cleanup is needed even if the response is lost.
                requireSuccess(command(BleControlProbeProtocol.remoteMode(true)))
                val feature = command(BleControlProbeProtocol.featureQuery())
                val configuration = command(BleControlProbeProtocol.configurationQuery())
                requireSuccess(feature)
                requireSuccess(configuration)
                check(feature.remoteControl == true) {
                    "相机未声明遥控支持，请复制日志"
                }
                selectorSupported = configuration.selector == true
                if (configuration.menu != true) {
                    // A separate, explicit diagnostic action may try the known MENU key once.
                    // Do not infer support or navigate automatically from a missing capability.
                    mutableState.value = state.value.copy(
                        remoteActive = true,
                        canTestMenu = false,
                        canVerifyMenu = true,
                        summary = "未声明菜单键支持，可单次验证；尚未发送菜单按键",
                    )
                    record("Menu not advertised. No MENU sent; awaiting explicit one-shot verification")
                    return@runOperation
                }
                record("Remote-session capabilities confirmed. menu=true selector=${configuration.selector}; STA not verified")
            }
            sendMenuAndReadStatus()
        }
    }

    fun verifyUnadvertisedMenuOnce() {
        if (!state.value.canVerifyMenu || state.value.busy || !state.value.connected || !state.value.remoteActive) return
        mutableState.value = state.value.copy(canVerifyMenu = false)
        runOperation("正在验证菜单键") {
            record("EXPLICIT one-shot MENU verification despite absent capability; no automatic navigation")
            sendMenuAndReadStatus()
        }
    }

    private suspend fun sendMenuAndReadStatus() {
        tap(5)
        find(STATUS)?.let {
            if (it.properties and BluetoothGattCharacteristic.PROPERTY_READ != 0) {
                val (status, bytes) = read(it)
                record("STATUS after MENU readStatus=$status ${bytes.hex()}")
                if (status == 0) record(BleControlProbeProtocol.describeStatus(bytes))
            }
        }
        mutableState.value = state.value.copy(
            remoteActive = true,
            canNavigate = selectorSupported,
            summary = "菜单按键已确认，请观察机身是否打开菜单",
        )
    }

    fun pressKey(key: Int) {
        if (!state.value.remoteActive || !state.value.canNavigate || state.value.busy || key !in 7..11) return
        runOperation("正在发送按键") {
            tap(key)
            mutableState.value = state.value.copy(summary = "按键已确认，请观察相机屏幕")
        }
    }

    private fun runOperation(summary: String, action: suspend () -> Unit) {
        val token = generation
        idleJob?.cancel()
        mutableState.value = state.value.copy(busy = true, summary = summary)
        job = scope.launch {
            try {
                check(!NikonGpsRuntime.state.value.enabled && !NikonGpsRuntime.wifiWakeState.value.isBusy) { "GPS 或热点唤醒正在运行" }
                action()
                mutableState.value = state.value.copy(busy = false)
                saveLog()
                armIdleTimeout()
            } catch (error: Exception) {
                if (token == generation) fail(error.message ?: "蓝牙操作失败")
            } finally {
                if (token == generation) job = null
            }
        }
    }

    private suspend fun tap(key: Int) {
        pressedKey = key
        val down = command(BleControlProbeProtocol.key(key, true))
        // Always release before reporting a rejected press, so the user cannot leave a key held.
        val up = command(BleControlProbeProtocol.key(key, false))
        requireSuccess(up)
        pressedKey = null
        requireSuccess(down)
    }

    fun stop() {
        generation++
        job?.cancel()
        job = null
        idleJob?.cancel()
        idleJob = null
        val current = gatt
        val control = find(CONTROL)
        if (current != null && control != null) {
            // Best effort only: disconnect is the final cleanup, never claim an unobserved ACK.
            pressedKey?.let { key -> runCatching { writeRaw(current, control, BleControlProbeProtocol.key(key, false)) } }
            if (remoteRequested && pressedKey == null) runCatching { writeRaw(current, control, BleControlProbeProtocol.remoteMode(false)) }
        }
        pressedKey = null
        remoteRequested = false
        selectorSupported = false
        client?.stop()
        client = null
        gatt = null
        readReply?.cancel(); readReply = null
        descriptorReply?.cancel(); descriptorReply = null
        writeReply?.cancel(); writeReply = null
        controlReply?.cancel(); controlReply = null
        expectedRead = null; expectedDescriptor = null; expectedOpcode = null
        if (state.value.connected || state.value.busy) record("Probe disconnected; remote-stop delivery not assumed; no STA success inferred")
        mutableState.value = state.value.copy(busy = false, connected = false, canTestMenu = false, canVerifyMenu = false, canNavigate = false, remoteActive = false, summary = "已断开，可复制日志")
        saveLog()
    }

    fun close() = stop()

    private fun fail(message: String) {
        record("ERROR $message")
        stop()
        mutableState.value = state.value.copy(summary = message)
    }

    private fun finishUnsupported(message: String) {
        record(message)
        stop()
        mutableState.value = state.value.copy(summary = message)
    }

    private fun armIdleTimeout() {
        idleJob?.cancel()
        idleJob = scope.launch { delay(120_000); record("Idle timeout"); stop() }
    }

    private fun listener(token: Int, connected: CompletableDeferred<BluetoothGatt>) = object : NikonGpsBleClient.Listener {
        override fun onConnecting(name: String?) { if (token == generation) record("Connecting ${name ?: "Nikon"}") }
        override fun onBleAddress(address: String) {}
        override fun onPairing() { onError("需要先在 GPS 功能完成配对") }
        override fun onReady(name: String, device: BluetoothDevice) {
            if (token != generation) return
            val authenticated = client?.debugAuthenticatedGatt()
            if (authenticated == null) onError("蓝牙认证未确认")
            else { record("Authenticated camera=$name"); connected.complete(authenticated) }
        }
        override fun onGeoWritten(success: Boolean) {}
        override fun onPairedIdentity(device: Long, nonce: Long) {}
        override fun onDisconnected() { onError("相机蓝牙已断开；是否切换网络需观察机身") }
        override fun onNeedsPairing() { onError("配对已失效，请先在 GPS 功能重新配对") }
        override fun onError(message: String) {
            if (token != generation) return
            if (!connected.isCompleted) connected.completeExceptionally(IllegalStateException(message))
            else fail(message)
        }
        override fun onDebugRead(uuid: UUID, value: ByteArray, status: Int) {
            if (token == generation && uuid == expectedRead) readReply?.complete(status to value)
        }
        override fun onDebugWrite(uuid: UUID, status: Int) {
            if (token == generation && uuid == CONTROL) writeReply?.complete(status)
        }
        override fun onDebugDescriptorWrite(uuid: UUID, status: Int) {
            if (token == generation && uuid == expectedDescriptor) descriptorReply?.complete(status)
        }
        override fun onDebugNotification(uuid: UUID, value: ByteArray) {
            if (token != generation) return
            if (uuid == STATUS) record("STATUS ${value.hex()} ${BleControlProbeProtocol.describeStatus(value)}")
            if (uuid == CONTROL) {
                record("RX ${value.hex()}")
                val parsed = BleControlProbeProtocol.parseResponse(value)
                if (parsed == null) record("Malformed/unknown control response; not accepted")
                else if (parsed.opcode == expectedOpcode) controlReply?.complete(parsed)
                else record("Unsolicited opcode=${parsed.opcode}; ignored")
            }
        }
    }

    private suspend fun read(ch: BluetoothGattCharacteristic): Pair<Int, ByteArray> = withTimeout(8_000) {
        val reply = CompletableDeferred<Pair<Int, ByteArray>>()
        expectedRead = ch.uuid
        readReply = reply
        try { check(requireNotNull(gatt).readCharacteristic(ch)) { "读取请求被拒绝 ${ch.uuid}" }; reply.await() }
        finally { if (readReply === reply) { readReply = null; expectedRead = null } }
    }

    private suspend fun enableUpdates(ch: BluetoothGattCharacteristic) = withTimeout(8_000) {
        val current = requireNotNull(gatt)
        val descriptor = requireNotNull(ch.getDescriptor(NikonGpsBleClient.CCCD_UUID)) { "缺少通知描述符 ${ch.uuid}" }
        val bytes = if (ch.properties and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0) BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
        else { check(ch.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) { "缺少响应通知 ${ch.uuid}" }; BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE }
        val reply = CompletableDeferred<Int>()
        expectedDescriptor = ch.uuid
        descriptorReply = reply
        try {
            check(current.setCharacteristicNotification(ch, true)) { "无法开启通知 ${ch.uuid}" }
            val accepted = if (Build.VERSION.SDK_INT >= 33) current.writeDescriptor(descriptor, bytes) == BluetoothGatt.GATT_SUCCESS
            else { @Suppress("DEPRECATION") descriptor.value = bytes; @Suppress("DEPRECATION") current.writeDescriptor(descriptor) }
            check(accepted) { "通知请求被拒绝 ${ch.uuid}" }
            check(reply.await() == 0) { "通知设置失败 ${ch.uuid}" }
            record("Subscribed ${ch.uuid}")
        } finally { if (descriptorReply === reply) { descriptorReply = null; expectedDescriptor = null } }
    }

    private suspend fun command(bytes: ByteArray): ControlProbeResponse = withTimeout(8_000) {
        val ack = CompletableDeferred<Int>()
        val reply = CompletableDeferred<ControlProbeResponse>()
        writeReply = ack
        controlReply = reply
        expectedOpcode = bytes[2].toInt() and 255
        record("TX ${bytes.hex()}")
        try {
            check(writeRaw(requireNotNull(gatt), requireNotNull(find(CONTROL)), bytes)) { "控制请求被拒绝" }
            check(ack.await() == 0) { "蓝牙写入失败" }
            reply.await().also { record("CONTROL ${it.details}") }
        } finally {
            if (writeReply === ack) writeReply = null
            if (controlReply === reply) { controlReply = null; expectedOpcode = null }
        }
    }

    @Suppress("DEPRECATION")
    private fun writeRaw(current: BluetoothGatt, ch: BluetoothGattCharacteristic, bytes: ByteArray): Boolean {
        if (Build.VERSION.SDK_INT >= 33) return current.writeCharacteristic(ch, bytes, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) == BluetoothGatt.GATT_SUCCESS
        ch.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        ch.value = bytes
        return current.writeCharacteristic(ch)
    }

    private fun requireSuccess(response: ControlProbeResponse) { check(response.responseCode == 1) { "相机拒绝操作（${response.responseCode}），请复制日志" } }
    private fun find(uuid: UUID): BluetoothGattCharacteristic? = gatt?.services?.firstNotNullOfOrNull { it.getCharacteristic(uuid) }
    private fun record(message: String) {
        if (entries.size >= 240) entries.removeFirst()
        entries.addLast("${Instant.now()} $message")
        mutableState.value = state.value.copy(log = entries.joinToString("\n"))
    }
    private fun saveLog() {
        if (state.value.log.isNotBlank()) logPreferences.edit().putString("last_log", state.value.log).apply()
    }
    private fun ByteArray.hex() = joinToString("") { "%02X".format(it.toInt() and 255) }

    private companion object {
        fun lss(value: String) = UUID.fromString("0000$value-3dd4-4255-8d62-6dc7b9bd5561")
        val CONTROL = lss("2021")
        val STATUS = lss("2020")
        val POWER = lss("2001")
        val FEATURE = lss("2009")
        val DEVICE_INFO = UUID.fromString("0000180a-0000-1000-8000-00805f9b34fb")
        val MODEL = UUID.fromString("00002a24-0000-1000-8000-00805f9b34fb")
        val FIRMWARE = UUID.fromString("00002a26-0000-1000-8000-00805f9b34fb")
    }
}
