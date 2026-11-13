package com.ztransfer.gps

import android.Manifest
import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Real LocationManager subscriptions and Main dispatcher jobs; no BLE connection or camera. */
class GpsLifecycleInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val result = Bundle()
        var code = Activity.RESULT_CANCELED
        val previousState = main { NikonGpsRuntime.state.value }
        try {
            requirePermissions()
            val manager = targetContext.getSystemService(LocationManager::class.java)
            check(manager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                "Enable the emulator's location setting before running this suite"
            }
            assertSubscriptions(present = false, label = "baseline")
            checkHandoff()
            for (action in listOf("stopGps", "stopActiveConnection", "handleBluetoothOff",
                "onError", "onDisconnected", "onDestroy")) checkStopPath(action)
            checkGattTimeoutCleanup()
            result.putString("result", "PASS: real LocationManager warmup/handoff/removal; " +
                "pre-auth location and GEO gates; six shutdown paths; old GATT timeout cancellation. " +
                "No real BLE connection or camera authentication was exercised.")
            code = Activity.RESULT_OK
        } catch (failure: Throwable) {
            result.putString("failure", failure.stackTraceToString())
        } finally {
            main { NikonGpsRuntime.state.value = previousState }
        }
        finish(code, result)
    }

    private fun checkHandoff() = withFixture { fixture ->
        val warmup = startWarmup(fixture)
        assertSubscriptions(present = true, label = "warmup")
        main {
            val before = NikonGpsRuntime.state.value
            val fix = Location(LocationManager.GPS_PROVIDER).apply {
                latitude = 31.2
                longitude = 121.4
                altitude = -12.5
                accuracy = 5f
                time = System.currentTimeMillis()
                elapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos()
            }
            (field(fixture.service, "locationListener") as LocationListener).onLocationChanged(fix)
            check(NikonGpsRuntime.state.value == before) { "Pre-auth fix changed the UI" }
            check(field(fixture.service, "latestLocation") == null)
            check(field(fixture.service, "geoWriteInFlight") == false)
            check(field(fixture.ble, "pendingGeo") == null)
            invoke(fixture.service, "maybeSend", fix, true)
            check(field(fixture.ble, "pendingGeo") == null) { "Pre-auth GEO was queued" }

            // Simulate only the authenticated-session boundary. Never fabricate a GATT or
            // claim that a real camera accepted a location write in this lifecycle test.
            setField(fixture.service, "cameraReady", true)
            NikonGpsRuntime.state.value = before.copy(status = GpsStatus.CONNECTED)
            invoke(fixture.service, "restartLocationPipeline")
            check(warmup.isCancelled) { "Normal pipeline retained the warmup timeout" }
            check(field(fixture.service, "locationWarmupJob") == null)
            check((field(fixture.service, "periodicGeoWriteJob") as Job).isActive)
        }
        assertSubscriptions(present = true, label = "normal handoff")
        main {
            invoke(fixture.service, "stopGps")
            assertStopped(fixture, warmup)
        }
        assertSubscriptions(present = false, label = "normal stop")
    }

    private fun checkStopPath(action: String) = withFixture { fixture ->
        val warmup = startWarmup(fixture)
        assertSubscriptions(present = true, label = "$action before")
        main {
            try {
                when (action) {
                    "onError" -> fixture.service.onError("Lifecycle fixture failure")
                    "onDisconnected" -> fixture.service.onDisconnected()
                    "onDestroy" -> fixture.destroy()
                    else -> invoke(fixture.service, action)
                }
                assertStopped(fixture, warmup)
            } finally {
                // These two callbacks may schedule a real reconnect. Cancel in the same
                // main-thread turn, before shell inspection can let their delay elapse.
                (field(fixture.service, "reconnectJob") as? Job)?.cancel()
                setField(fixture.service, "reconnectJob", null)
            }
        }
        assertSubscriptions(present = false, label = action)
    }

    private fun checkGattTimeoutCleanup() = withFixture { fixture ->
        var timeoutFired = false
        main {
            val packet = GpsPairingPacket(1, 123L, 456L, 789L)
            val pairingTimeout = fixture.scope.launch { delay(100); timeoutFired = true }
            val setupTimeout = fixture.scope.launch { delay(100); timeoutFired = true }
            setField(fixture.ble, "stage1", packet)
            setField(fixture.ble, "pairingTimeout", pairingTimeout)
            setField(fixture.ble, "setupTimeout", setupTimeout)
            invoke(fixture.ble, "clearGattOperationState")
            check(pairingTimeout.isCancelled && setupTimeout.isCancelled)
            check(field(fixture.ble, "pairingTimeout") == null)
            check(field(fixture.ble, "setupTimeout") == null)
            check(field(fixture.ble, "stage1") === packet) { "Classic pairing lost stage 1" }
        }
        SystemClock.sleep(150)
        main { check(!timeoutFired) { "An obsolete GATT timeout still executed" } }
    }

    private fun startWarmup(fixture: Fixture): Job = main {
        invoke(fixture.service, "warmLocationForReconnect")
        val job = field(fixture.service, "locationWarmupJob") as? Job
        check(job?.isActive == true) { "Warmup did not start: ${GpsDiagnostics.snapshot()}" }
        check(field(fixture.service, "cameraReady") == false)
        check(field(fixture.service, "geoWriteInFlight") == false)
        check(field(fixture.ble, "pendingGeo") == null)
        check(NikonGpsRuntime.state.value.status == GpsStatus.CONNECTING)
        checkNotNull(job)
    }

    private fun assertStopped(fixture: Fixture, warmup: Job) {
        check(warmup.isCancelled) { "Warmup job survived shutdown" }
        check(field(fixture.service, "locationWarmupJob") == null)
        check(field(fixture.service, "cameraReady") == false)
        check(field(fixture.service, "periodicGeoWriteJob") == null)
        check(field(fixture.service, "geoWriteTimeoutJob") == null)
    }

    private inner class Fixture {
        val preferencesName = "gps_lifecycle_test_${System.nanoTime()}"
        val service = NikonGpsService()
        val scope = field(service, "serviceScope") as CoroutineScope
        val ble = NikonGpsBleClient(targetContext, scope, service)
        private var destroyed = false

        init {
            ContextWrapper::class.java.getDeclaredMethod("attachBaseContext", Context::class.java)
                .apply { isAccessible = true }.invoke(service, targetContext)
            val preferences = targetContext.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            check(preferences.edit().putBoolean("enabled", true).commit())
            setField(service, "preferences", preferences)
            setField(service, "locationManager", targetContext.getSystemService(LocationManager::class.java))
            setField(service, "bleClient", ble)
            setField(service, "enabled", true)
            NikonGpsRuntime.state.value = GpsState(enabled = true, status = GpsStatus.CONNECTING)
        }

        fun destroy() {
            if (destroyed) return
            destroyed = true
            service.onDestroy()
        }
    }

    private fun withFixture(block: (Fixture) -> Unit) {
        val fixture = main { Fixture() }
        try { block(fixture) }
        finally {
            main {
                (field(fixture.service, "reconnectJob") as? Job)?.cancel()
                fixture.destroy()
                targetContext.deleteSharedPreferences(fixture.preferencesName)
            }
            assertSubscriptions(present = false, label = "fixture cleanup")
        }
    }

    /** Only current registration blocks count; event history also contains the package name. */
    private fun assertSubscriptions(present: Boolean, label: String) {
        val deadline = SystemClock.uptimeMillis() + 2_000L
        var registrations: List<String>
        do {
            val dump = ParcelFileDescriptor.AutoCloseInputStream(
                uiAutomation.executeShellCommand("dumpsys location"),
            ).bufferedReader().use { it.readText() }
            check(dump.contains("Location Providers:")) {
                "Cannot verify LocationManager registrations on this image: ${dump.take(1500)}"
            }
            val lines = dump.substringAfter("Location Providers:")
                .substringBefore("Historical Aggregate")
                .lineSequence().toList()
            val selected = ArrayList<String>()
            var indentation: Int? = null
            for (line in lines) {
                if (line.trim().lowercase() in setOf("registrations:", "listeners:")) {
                    indentation = line.indexOfFirst { !it.isWhitespace() }
                } else if (line.isNotBlank() && indentation != null) {
                    if (line.indexOfFirst { !it.isWhitespace() } <= indentation) indentation = null
                    else if (line.contains(targetContext.packageName) && line.contains(" Request[")) {
                        selected += line.trim()
                    }
                }
            }
            registrations = selected
            if (registrations.isNotEmpty() == present) return
            SystemClock.sleep(40)
        } while (SystemClock.uptimeMillis() < deadline)
        error("$label: expected subscription present=$present; current=$registrations")
    }

    private fun requirePermissions() {
        val permissions = buildList {
            add(Manifest.permission.ACCESS_FINE_LOCATION)
            add(Manifest.permission.ACCESS_COARSE_LOCATION)
            if (Build.VERSION.SDK_INT >= 31) add(Manifest.permission.BLUETOOTH_CONNECT)
        }
        for (permission in permissions) check(
            targetContext.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED,
        ) { "Grant $permission to ${targetContext.packageName} before running this suite" }
    }

    private fun field(target: Any, name: String): Any? = target.javaClass.getDeclaredField(name)
        .apply { isAccessible = true }.get(target)

    private fun setField(target: Any, name: String, value: Any?) = target.javaClass.getDeclaredField(name)
        .apply { isAccessible = true }.set(target, value)

    private fun invoke(target: Any, name: String, vararg arguments: Any?) = target.javaClass.declaredMethods
        .single { it.name == name && it.parameterCount == arguments.size }
        .apply { isAccessible = true }.invoke(target, *arguments)

    private fun <T> main(block: () -> T): T {
        var result: Result<T>? = null
        runOnMainSync { result = runCatching(block) }
        return checkNotNull(result).getOrThrow()
    }
}
