package com.ztransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RemoteBatteryTest {
    private fun battery(current: Long, dataType: Int = 0x0002, prop: Int = Lab.PROP_BATTERY_LEVEL) =
        RcParam(
            prop = prop,
            dataType = dataType,
            writable = false,
            current = current,
            values = emptyList()
        )

    @Test
    fun acceptsStandardUint8PercentageIncludingBoundaries() {
        assertEquals(0, rcBatteryPercentage(battery(0)))
        assertEquals(67, rcBatteryPercentage(battery(67)))
        assertEquals(100, rcBatteryPercentage(battery(100)))
    }

    @Test
    fun rejectsUnknownAndMalformedBatteryValues() {
        assertNull(rcBatteryPercentage(null))
        assertNull(rcBatteryPercentage(battery(-1)))
        assertNull(rcBatteryPercentage(battery(101)))
        assertNull(rcBatteryPercentage(battery(0xFF)))
        assertNull(rcBatteryPercentage(battery(50, dataType = 0x0004)))
        assertNull(rcBatteryPercentage(battery(50, prop = Lab.PROP_ISO)))
    }
}
