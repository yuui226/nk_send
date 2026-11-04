@file:Suppress("NOTHING_TO_INLINE")

package com.ztransfer.protocol

// Compile-time no-ops: Release contains no probe context, callback or transport override.
internal suspend inline fun NikonCamera.runStaProbeSession(): Boolean = false

internal suspend inline fun NikonCamera.isStaProbeSessionActive(): Boolean = false
