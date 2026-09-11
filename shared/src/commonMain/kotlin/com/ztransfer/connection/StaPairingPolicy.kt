package com.ztransfer.connection

import com.ztransfer.protocol.PtpConstants

/** STA-only initiator identities. The album identity never replaces the paired computer identity. */
enum class StaInitiatorIdentity {
    PAIRED_COMPUTER,
    ALBUM_EXPLORER,
}

fun isStaPairingOnlyOperationSet(operations: Set<Int>): Boolean = operations == setOf(
    PtpConstants.GET_DEVICE_INFO,
    PtpConstants.OPEN_SESSION,
    PtpConstants.CLOSE_SESSION,
    PtpConstants.NK_PAIRING_QUERY,
    PtpConstants.NK_PAIRING_RESULT,
)

fun shouldForceStaProfilePairing(
    storageResponse: Int,
    forceProfilePairing: Boolean,
    allowPairing: Boolean,
    protocolPairingMarkerExists: Boolean,
): Boolean = storageResponse == PtpConstants.RESPONSE_OK &&
    forceProfilePairing && allowPairing &&
    !protocolPairingMarkerExists

fun isExpectedStaResponder(
    expectedResponderGuid: String?,
    actualResponderGuid: String?,
): Boolean = expectedResponderGuid == null || expectedResponderGuid == actualResponderGuid

fun hasUsableStaAlbumStorage(response: Int, storageIds: List<Int>): Boolean =
    response == PtpConstants.RESPONSE_OK && storageIds.isNotEmpty()
