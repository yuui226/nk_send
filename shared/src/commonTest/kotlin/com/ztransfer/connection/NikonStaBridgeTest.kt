package com.ztransfer.connection

import com.ztransfer.protocol.LabDeviceInfo
import com.ztransfer.protocol.PtpConstants
import kotlin.test.*

class NikonStaBridgeTest {
    @Test fun optionalMetadataCommandsRequireActualAdvertisedOperations() {
        val info = LabDeviceInfo("Nikon", "Test", "1", "", 0, 0, "", setOf(0x9434), emptySet(), emptySet())
        assertTrue(NikonStaBridge.advertises(info, 0x9434))
        assertFalse(NikonStaBridge.advertises(info, 0x9805)); assertFalse(NikonStaBridge.advertises(null, 0x9434))
    }
    @Test
    fun storageAndForcedPairingKeepExistingDecisions() {
        for (code in listOf(PtpConstants.RESPONSE_OK, PtpConstants.DEVICE_BUSY, 0x200F)) {
            for (ids in listOf(intArrayOf(), intArrayOf(0), intArrayOf(0x10001, -1))) {
                assertEquals(hasUsableStaAlbumStorage(code, ids.toList()), NikonStaBridge.usableStorage(code, ids))
            }
            for (force in listOf(false, true)) for (allow in listOf(false, true)) for (marked in listOf(false, true)) {
                assertEquals(shouldForceStaProfilePairing(code, force, allow, marked), NikonStaBridge.forcePairing(code, force, allow, marked))
            }
        }
    }

    @Test
    fun responderAndPairingOnlyOperationsRemainStrict() {
        val guid = "00112233445566778899aabbccddeeff"
        assertEquals(guid, NikonStaBridge.normalizeGuid("  ${guid.uppercase()}  "))
        assertNull(NikonStaBridge.normalizeGuid("unknown"))
        assertTrue(NikonStaBridge.expectedResponder(null, null))
        assertFalse(NikonStaBridge.expectedResponder(guid, null))
        val operations = setOf(0x1001, 0x1002, 0x1003, 0x952B, 0x935A)
        val info = LabDeviceInfo("Nikon", "Test", "1", "", 0, 0, "", operations, emptySet(), emptySet())
        assertTrue(NikonStaBridge.pairingOnly(info))
        assertFalse(NikonStaBridge.pairingOnly(info.copy(operations = operations + 0x1004)))
        assertFalse(NikonStaBridge.pairingOnly(null))
        assertEquals(0x941C, NikonStaBridge.COMPATIBILITY_INIT)
        assertEquals(8000L, NikonStaBridge.PAIRING_EVENT_TIMEOUT_MS)
    }
}
