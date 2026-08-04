package com.ztransfer.protocol

import android.content.Intent

/** Release implementation: production camera discovery cannot be overridden. */
object CameraEndpointOverride {
    fun applyLaunchIntent(@Suppress("UNUSED_PARAMETER") intent: Intent?) = Unit

    fun enableSimulator(): Boolean = false

    fun hostOrNull(): String? = null
}
