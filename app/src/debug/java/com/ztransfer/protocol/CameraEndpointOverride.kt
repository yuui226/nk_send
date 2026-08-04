package com.ztransfer.protocol

/** Debug-only endpoint backed by the embedded camera simulator in the app process. */
object CameraEndpointOverride {
    private const val SIMULATOR_HOST = "127.0.0.1"

    fun applyLaunchIntent(@Suppress("UNUSED_PARAMETER") intent: android.content.Intent?) {
        DebugCameraSimulator.start()
    }

    fun hostOrNull(): String? = SIMULATOR_HOST
}
