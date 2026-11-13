package com.ztransfer.viewmodel

import com.ztransfer.R
import com.ztransfer.protocol.CameraRefusedException
import com.ztransfer.protocol.PairingNotConfirmedException
import com.ztransfer.protocol.StaPairingConfirmationMissingException
import com.ztransfer.protocol.StaResponseException
import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class StaFailureMessageTest {
    @Test fun cancelledStaResponseSuggestsCheckingPhotos() {
        val error = StaResponseException(0x201F, "Nikon pairing query failed: 0x201f")
        assertEquals(R.string.sta_camera_check_photos, staFailureMessageResource(error, false))
        assertEquals(R.string.sta_camera_check_photos, staFailureMessageResource(error, true))
        assertFalse(isTransientStaServiceReadinessFailure(error))
    }

    @Test fun pairingWrappersRetainTheActionableCause() {
        val error = StaPairingConfirmationMissingException(
            PairingNotConfirmedException(StaResponseException(0x201F, "rejected")),
        )
        assertEquals(R.string.sta_camera_check_photos, staFailureMessageResource(error, false))
        assertFalse(shouldKeepStaDiscoveryAlive(true, true, error))
    }

    @Test fun otherCodesAndNonStaErrorsDoNotGetTheEmptyCardSuggestion() {
        assertNull(staFailureMessageResource(StaResponseException(0x2019, "busy"), false))
        assertNull(staFailureMessageResource(IOException("transfer cancelled: 0x201f"), false))
        assertNull(staFailureMessageResource(null, false))
        assertEquals(
            R.string.sta_pairing_incomplete,
            staFailureMessageResource(StaPairingConfirmationMissingException(IOException("EOF")), false),
        )
    }

    @Test fun existingRefusalHintsRemainUnchanged() {
        val error = CameraRefusedException("refused")
        assertEquals(R.string.sta_camera_refused_repair, staFailureMessageResource(error, false))
        assertEquals(R.string.sta_camera_refused_retrying, staFailureMessageResource(error, true))
    }
}
