package com.ztransfer.protocol

import kotlin.test.Test
import kotlin.test.assertEquals

class RcSetResultTest {
    private val actual = RcParam(
        prop = Lab.PROP_ISO,
        dataType = 0x0004, // PTP UINT16
        writable = true,
        current = 400L,
        values = listOf(100L, 200L, 400L),
    )

    @Test
    fun keepsConfirmedReadBackDistinctFromRejectedWrite() {
        assertEquals(
            RcSetResult(Lab.OK, actual, confirmed = true),
            RcSetResult(Lab.OK, actual, confirmed = true).copy(),
        )
        assertEquals(
            RcSetResult(Lab.DEVICE_BUSY, actual = null, confirmed = false),
            RcSetResult(Lab.DEVICE_BUSY, actual = null, confirmed = false),
        )
        assertEquals(
            RcSetResult(Lab.OK, actual, confirmed = false),
            RcSetResult(Lab.OK, actual, confirmed = false),
        )
    }
}
