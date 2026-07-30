package com.ztransfer.protocol

import android.content.Intent

/**
 * Debug-only ADB reverse endpoint. The enabling extra and loopback address do not exist in
 * the Release source set, so a production build cannot activate or discover this path.
 */
object CameraEndpointOverride {
    private const val EXTRA_LOOPBACK_CAMERA = "com.ztransfer.debug.LOOPBACK_CAMERA"
    private const val LOOPBACK_HOST = "127.0.0.1"

    @Volatile
    private var enabled = false

    fun applyLaunchIntent(intent: Intent?) {
        enabled = intent?.getBooleanExtra(EXTRA_LOOPBACK_CAMERA, false) == true
    }

    fun hostOrNull(): String? = LOOPBACK_HOST.takeIf { enabled }
}
