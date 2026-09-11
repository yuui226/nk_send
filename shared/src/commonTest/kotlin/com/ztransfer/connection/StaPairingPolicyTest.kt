package com.ztransfer.connection

import com.ztransfer.protocol.PtpConstants
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class StaPairingPolicyTest {
    private val pairingOperations = setOf(
        PtpConstants.GET_DEVICE_INFO,
        PtpConstants.OPEN_SESSION,
        PtpConstants.CLOSE_SESSION,
        PtpConstants.NK_PAIRING_QUERY,
        PtpConstants.NK_PAIRING_RESULT,
    )

    @Test
    fun initiatorIdentityPersistenceNamesRemainStable() {
        assertEquals(
            listOf("PAIRED_COMPUTER", "ALBUM_EXPLORER"),
            StaInitiatorIdentity.entries.map(StaInitiatorIdentity::name),
        )
    }

    @Test
    fun onlyTheExactPairingCapabilitySetRequiresPairing() {
        assertTrue(isStaPairingOnlyOperationSet(pairingOperations))
        assertFalse(isStaPairingOnlyOperationSet(pairingOperations + 0x9439))
        assertFalse(
            isStaPairingOnlyOperationSet(
                pairingOperations - PtpConstants.NK_PAIRING_RESULT,
            ),
        )
    }

    @Test
    fun profilePairingRequiresEveryProtocolCondition() {
        assertTrue(
            shouldForceStaProfilePairing(
                storageResponse = PtpConstants.RESPONSE_OK,
                forceProfilePairing = true,
                allowPairing = true,
                protocolPairingMarkerExists = false,
            ),
        )
        assertFalse(
            shouldForceStaProfilePairing(
                storageResponse = 0x2002,
                forceProfilePairing = true,
                allowPairing = true,
                protocolPairingMarkerExists = false,
            ),
        )
        assertFalse(
            shouldForceStaProfilePairing(
                storageResponse = PtpConstants.RESPONSE_OK,
                forceProfilePairing = false,
                allowPairing = true,
                protocolPairingMarkerExists = false,
            ),
        )
        assertFalse(
            shouldForceStaProfilePairing(
                storageResponse = PtpConstants.RESPONSE_OK,
                forceProfilePairing = true,
                allowPairing = false,
                protocolPairingMarkerExists = false,
            ),
        )
        assertFalse(
            shouldForceStaProfilePairing(
                storageResponse = PtpConstants.RESPONSE_OK,
                forceProfilePairing = true,
                allowPairing = true,
                protocolPairingMarkerExists = true,
            ),
        )
    }

    @Test
    fun albumStorageUsesTheExistingResponseAndNonEmptyRule() {
        assertFalse(hasUsableStaAlbumStorage(PtpConstants.RESPONSE_OK, emptyList()))
        assertFalse(hasUsableStaAlbumStorage(0x2002, listOf(0x00010001)))
        assertTrue(hasUsableStaAlbumStorage(PtpConstants.RESPONSE_OK, listOf(0x00010001)))
        assertTrue(hasUsableStaAlbumStorage(PtpConstants.RESPONSE_OK, listOf(0)))
        assertTrue(hasUsableStaAlbumStorage(PtpConstants.RESPONSE_OK, listOf(-1)))
    }

    @Test
    fun responderMatchingPreservesNullAndExactStringSemantics() {
        val expected = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        assertTrue(isExpectedStaResponder(expected, expected))
        assertTrue(isExpectedStaResponder(null, "22222222222222222222222222222222"))
        assertTrue(isExpectedStaResponder(null, null))
        assertFalse(isExpectedStaResponder(expected, null))
        assertFalse(isExpectedStaResponder(expected, "22222222222222222222222222222222"))
        assertFalse(isExpectedStaResponder(expected, expected.uppercase()))
    }
}
