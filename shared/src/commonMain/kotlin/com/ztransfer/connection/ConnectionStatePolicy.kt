package com.ztransfer.connection

import com.ztransfer.protocol.CameraConnectionType

enum class WifiConnectionStatus {
    IDLE,
    PROBING,
    NOT_FOUND,
    REFUSED,
    FAILED,
    RECONNECTING,
}

enum class StaConnectionStatus {
    IDLE,
    DISCOVERING,
    PAIRING,
    CONNECTING,
    FAILED,
}

enum class WirelessMode {
    AP,
    STA,
}

fun restoredWirelessMode(value: String?): WirelessMode =
    runCatching { WirelessMode.valueOf(value.orEmpty()) }.getOrDefault(WirelessMode.STA)

fun restoredStaInitiatorIdentity(value: String?): StaInitiatorIdentity =
    runCatching { StaInitiatorIdentity.valueOf(value.orEmpty()) }
        .getOrDefault(StaInitiatorIdentity.PAIRED_COMPUTER)

/** STA reconnection is selected only for an established STA-origin Wi-Fi session. */
fun shouldReconnectUsingSta(
    connectionType: CameraConnectionType?,
    wirelessMode: WirelessMode,
): Boolean = connectionType == CameraConnectionType.WIFI && wirelessMode == WirelessMode.STA

/** Keeps an already-started STA discovery alive through Nikon's service restart or reconnect. */
fun shouldKeepStaDiscoveryAlive(
    reconnectRequested: Boolean,
    hasReusableProfile: Boolean,
): Boolean = reconnectRequested || hasReusableProfile

/** A reconnect request that overlaps the tail of the previous scan must be retried, not dropped. */
fun shouldScheduleStaDiscoveryRetry(
    reconnectRequested: Boolean,
    discoveryInProgress: Boolean,
): Boolean = reconnectRequested && discoveryInProgress

/** Album access alone is not proof that Nikon finished the computer-profile pairing. */
fun canActivateStaSession(
    albumAccessValidated: Boolean,
    pairingConfirmed: Boolean,
): Boolean = albumAccessValidated && pairingConfirmed

private val STA_RECONNECT_DELAYS_MS = longArrayOf(3_000L, 8_000L, 15_000L, 30_000L)

fun staReconnectDelayMs(attempt: Int): Long = STA_RECONNECT_DELAYS_MS[
    attempt.coerceAtMost(STA_RECONNECT_DELAYS_MS.lastIndex)
]
