package com.ztransfer.protocol

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StaPairingStateTest {
    private val pairingOperations = setOf(
        PtpConstants.GET_DEVICE_INFO,
        PtpConstants.OPEN_SESSION,
        PtpConstants.CLOSE_SESSION,
        PtpConstants.NK_PAIRING_QUERY,
        PtpConstants.NK_PAIRING_RESULT,
    )

    @Test
    fun exactPairingCapabilitySetRequiresPairing() {
        assertTrue(isStaPairingOnlyOperationSet(pairingOperations))
    }

    @Test
    fun pairedTransferCapabilitySetMustNotPairAgain() {
        assertFalse(isStaPairingOnlyOperationSet(pairingOperations + 0x9439))
    }

    @Test
    fun incompleteCapabilitySetIsNotTreatedAsPairingState() {
        assertFalse(isStaPairingOnlyOperationSet(pairingOperations - PtpConstants.NK_PAIRING_RESULT))
    }

    @Test
    fun successfulResponseWithoutStorageIsNotAlbumAccess() {
        assertFalse(hasUsableStaAlbumStorage(PtpConstants.RESPONSE_OK, emptyList()))
    }

    @Test
    fun successfulResponseWithStorageIsAlbumAccess() {
        assertTrue(hasUsableStaAlbumStorage(PtpConstants.RESPONSE_OK, listOf(0x00010001)))
    }

    @Test
    fun knownCameraProfileIsNeverForcedBackThroughPairing() {
        assertFalse(
            shouldForceStaProfilePairing(
                storageResponse = PtpConstants.RESPONSE_OK,
                forceProfilePairing = true,
                allowPairing = true,
                knownCameraProfile = true,
                protocolPairingMarkerExists = false,
            ),
        )
    }

    @Test
    fun newCameraStillCompletesProfilePairing() {
        assertTrue(
            shouldForceStaProfilePairing(
                storageResponse = PtpConstants.RESPONSE_OK,
                forceProfilePairing = true,
                allowPairing = true,
                knownCameraProfile = false,
                protocolPairingMarkerExists = false,
            ),
        )
    }

    @Test
    fun responderGuidCheckDefersWrongOrMissingDhcpCandidate() {
        val expected = "11111111111111111111111111111111"
        assertTrue(isExpectedStaResponder(expected, expected))
        assertTrue(isExpectedStaResponder(null, "22222222222222222222222222222222"))
        assertFalse(isExpectedStaResponder(expected, null))
        assertFalse(isExpectedStaResponder(expected, "22222222222222222222222222222222"))
    }
}
