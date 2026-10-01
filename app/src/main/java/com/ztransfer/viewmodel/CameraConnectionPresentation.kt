package com.ztransfer.viewmodel

import com.ztransfer.protocol.CameraConnectionType

/** The transport shown to the user, including a remembered disconnected session. */
enum class CameraConnectionMode { USB, AP, STA }

internal fun restoredConnectionMode(value: String?): CameraConnectionMode? =
    CameraConnectionMode.entries.firstOrNull { it.name == value }

/** Actual session/USB attachment wins; saved presentation must never select a protocol route. */
internal val CameraState.connectionMode: CameraConnectionMode
    get() = when (connectionType) {
        CameraConnectionType.USB -> CameraConnectionMode.USB
        CameraConnectionType.WIFI -> if (isStaConnection) CameraConnectionMode.STA else CameraConnectionMode.AP
        null -> rememberedConnectionMode ?: if (wirelessMode == WirelessMode.STA) {
            CameraConnectionMode.STA
        } else {
            CameraConnectionMode.AP
        }
    }

internal val CameraState.presentationConnectionType: CameraConnectionType
    get() = if (connectionMode == CameraConnectionMode.USB) CameraConnectionType.USB else CameraConnectionType.WIFI

internal val CameraState.presentationIsSta: Boolean
    get() = connectionMode == CameraConnectionMode.STA

/** Also accepts a restored STA page with no live session; discovery retains its own guards. */
internal val CameraState.canRetryStaConnection: Boolean
    get() = !isConnectedToCamera && connectionMode == CameraConnectionMode.STA
