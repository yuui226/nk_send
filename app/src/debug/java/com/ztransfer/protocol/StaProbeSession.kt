package com.ztransfer.protocol

import java.net.InetAddress
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.withContext

/** Scoped to one camera and one explicit experiment; ordinary connections cannot inherit it. */
private class StaProbeSession(
    val camera: NikonCamera,
    val body: suspend (NikonCamera) -> Unit,
) : AbstractCoroutineContextElement(Key) {
    companion object Key : CoroutineContext.Key<StaProbeSession>
}

/** Uses the normal transport handshake, then runs only the Debug experiment. No trust is saved. */
internal suspend fun NikonCamera.connectStaProbe(
    ip: String,
    localAddress: InetAddress? = null,
    expectedResponderGuid: String? = null,
    body: suspend (NikonCamera) -> Unit,
): Result<Unit> = withContext(StaProbeSession(this, body)) {
    connectSta(
        ip = ip,
        localAddress = localAddress,
        expectedResponderGuid = expectedResponderGuid,
        allowPairing = false,
    )
}

internal suspend fun NikonCamera.runStaProbeSession(): Boolean {
    val session = currentCoroutineContext()[StaProbeSession]
        ?.takeIf { it.camera === this } ?: return false
    session.body(this)
    return true
}

internal suspend fun NikonCamera.isStaProbeSessionActive(): Boolean =
    currentCoroutineContext()[StaProbeSession]?.camera === this

/** Refreshes capabilities from a diagnostic response without changing pairing trust. */
internal suspend fun NikonCamera.cacheStaProbeDeviceInfo(data: ByteArray): LabDeviceInfo {
    check(isStaProbeSessionActive())
    return cacheDeviceInfo(data)
}

/** Reuses album validation without pairing, activating the album or persisting trust. */
internal suspend fun NikonCamera.prepareStaProbeAlbumSession() {
    check(isStaProbeSessionActive())
    initializeStaBrowsingSession(
        allowPairing = false,
        exploreAlbumAccess = true,
        forceProfilePairing = false,
        verifyPairingCompletion = true,
        cleanupConfirmation = null,
        onConnectingStarted = null,
        onPairingStarted = null,
    )
}
