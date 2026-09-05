package com.ztransfer.ui.screen

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SharedSignalPillTest {
    @Test fun androidDefaultMatchesOriginalForAllConnectionModesAndSignalBoundaries() {
        val samples = listOf<Int?>(null, Int.MIN_VALUE, Int.MAX_VALUE) + (-120..0).toList()
        for (connected in listOf(false, true)) for (usb in listOf(false, true)) for (sta in listOf(false, true)) {
            for (rssi in samples) {
                val original = connected && (usb || sta || rssi != null)
                assertEquals(original, signalPillOnline(connected, usb, sta, rssi))
            }
        }
    }

    @Test fun unknownSignalRequiresExplicitCapabilityAndNeverMakesDisconnectedCameraOnline() {
        assertFalse(signalPillOnline(true, false, false, null))
        assertTrue(signalPillOnline(true, false, false, null, allowUnknownRssi = true))
        for (usb in listOf(false, true)) for (sta in listOf(false, true)) {
            assertFalse(signalPillOnline(false, usb, sta, null, allowUnknownRssi = true))
            assertEquals(signalPillOnline(true, usb, sta, -45), signalPillOnline(true, usb, sta, -45, true))
        }
    }
}
