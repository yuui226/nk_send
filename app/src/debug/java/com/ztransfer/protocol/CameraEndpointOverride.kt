package com.ztransfer.protocol

/**
 * Debug-only embedded camera endpoint. The simulator lives in the app process, so a manually
 * installed Debug APK needs neither ADB reverse nor access to the development computer.
 */
object CameraEndpointOverride {
    private const val SIMULATOR_HOST = "127.0.0.1"

    fun applyLaunchIntent(@Suppress("UNUSED_PARAMETER") intent: android.content.Intent?) {
        DebugCameraSimulator.start()
    }

    fun hostOrNull(): String? = SIMULATOR_HOST
}
