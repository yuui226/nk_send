package com.ztransfer.ui.screen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RemoteOrientationPolicyTest {

    @Test
    fun mapsStablePhoneDirectionsToExistingMonitorLayouts() {
        listOf(0, 15, 30, 330, 345, 359).forEach { orientation ->
            assertEquals("portrait $orientation", 0, remoteRotationForDeviceOrientation(orientation))
        }
        listOf(60, 90, 120).forEach { orientation ->
            assertEquals("left side at top $orientation", 2, remoteRotationForDeviceOrientation(orientation))
        }
        listOf(240, 270, 300).forEach { orientation ->
            assertEquals("right side at top $orientation", 1, remoteRotationForDeviceOrientation(orientation))
        }
    }

    @Test
    fun ignoresUnknownTransitionAndUpsideDownDirections() {
        listOf(-1, 31, 45, 59, 121, 180, 239, 301, 315, 329).forEach { orientation ->
            assertNull("orientation $orientation", remoteRotationForDeviceOrientation(orientation))
        }
    }
}
