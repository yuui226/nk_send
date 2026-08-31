package com.ztransfer.ui.screen

import com.ztransfer.gps.GpsState
import com.ztransfer.gps.GpsStatus
import org.junit.Assert.assertEquals
import org.junit.Test

class GpsConnectionPresentationTest {
    @Test
    fun connectedStatesCollapseIntoOneSuccessOutcome() {
        listOf(
            GpsStatus.PAIRING_SUCCESS,
            GpsStatus.CONNECTED,
            GpsStatus.WRITING,
            GpsStatus.WAITING_FIX,
            GpsStatus.READY,
        ).forEach { status ->
            assertEquals(
                GpsConnectionHapticOutcome.SUCCESS,
                GpsState(enabled = true, status = status).gpsConnectionHapticOutcome(),
            )
        }
    }

    @Test
    fun actionableConnectionFailuresCollapseIntoOneFailureOutcome() {
        listOf(
            GpsStatus.NEEDS_CAMERA,
            GpsStatus.AP_UNAVAILABLE,
            GpsStatus.ERROR,
        ).forEach { status ->
            assertEquals(
                GpsConnectionHapticOutcome.FAILURE,
                GpsState(enabled = true, status = status).gpsConnectionHapticOutcome(),
            )
        }
    }

    @Test
    fun disabledAndProgressStatesDoNotProduceResultHaptics() {
        GpsStatus.entries.forEach { status ->
            assertEquals(
                GpsConnectionHapticOutcome.NONE,
                GpsState(enabled = false, status = status).gpsConnectionHapticOutcome(),
            )
        }
        listOf(
            GpsStatus.OFF,
            GpsStatus.STARTING,
            GpsStatus.SEARCHING,
            GpsStatus.CONNECTING,
            GpsStatus.PAIRING,
            GpsStatus.CAMERA_CONFIRM,
        ).forEach { status ->
            assertEquals(
                GpsConnectionHapticOutcome.NONE,
                GpsState(enabled = true, status = status).gpsConnectionHapticOutcome(),
            )
        }
    }
}
