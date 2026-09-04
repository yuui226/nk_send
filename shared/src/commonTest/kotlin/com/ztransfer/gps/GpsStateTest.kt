package com.ztransfer.gps

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull

class GpsStateTest {
    @Test
    fun defaultStateRemainsDisabledAndEmpty() {
        val state = GpsState()

        assertFalse(state.enabled)
        assertEquals(GpsStatus.OFF, state.status)
        assertNull(state.cameraName)
        assertNull(state.latitude)
        assertNull(state.longitude)
        assertNull(state.altitudeMeters)
        assertNull(state.accuracyMeters)
        assertNull(state.lastSentAtMs)
        assertNull(state.message)
    }

    @Test
    fun statusNamesAndOrderRemainStable() {
        assertEquals(
            listOf(
                "OFF",
                "STARTING",
                "SEARCHING",
                "NEEDS_CAMERA",
                "CONNECTING",
                "PAIRING",
                "CAMERA_CONFIRM",
                "PAIRING_SUCCESS",
                "CONNECTED",
                "WRITING",
                "WAITING_FIX",
                "READY",
                "AP_UNAVAILABLE",
                "ERROR",
            ),
            GpsStatus.entries.map { it.name },
        )
    }
}
