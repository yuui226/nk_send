package com.ztransfer.protocol

import org.junit.Assert.*
import org.junit.Test

class RemoteExposureMeterTest {
    private fun meter(raw: Long) = RcParam(NIKON_LIGHT_METER, 0x0001, false, raw, emptyList())

    @Test fun signedTwelfthsConvertWithoutConfusingCompensation() {
        for (raw in listOf(-60L, -12L, -4L, 0L, 4L, 12L, 60L)) {
            assertEquals(raw / 12f, requireNotNull(rcExposureMeterEv(meter(raw))), 0.00001f)
        }
        assertNull(rcExposureMeterEv(meter(12).copy(prop = Lab.PROP_EXP_COMPENSATION)))

    }

    @Test fun exposureIndicateMovesExactlyOneMinorTickPerRawUnit() {
        for (raw in listOf(-12L, -4L, -1L, 0L, 1L, 4L, 12L)) {
            assertEquals(raw / 3f, requireNotNull(rcExposureMeterEv(
                meter(raw).copy(prop = NIKON_EXPOSURE_INDICATE))), 0f)
        }
    }

    @Test fun unknownTypesAndOutOfVerifiedRangeAreNotZero() {
        assertNull(rcExposureMeterEv(null))
        for (raw in listOf(-128L, -61L, 61L, 127L, 255L)) assertNull(rcExposureMeterEv(meter(raw)))
        assertNull(rcExposureMeterEv(meter(0).copy(dataType = 0x0002)))
        assertNull(rcExposureMeterEv(meter(0).copy(writable = true)))
    }

    @Test fun scalarPayloadMustBeCompleteAndSigned() {
        assertEquals(-12L, rcDecodeExposureMeterValue(meter(0), Lab.OK, byteArrayOf(0xf4.toByte()))?.current)
        assertEquals(0L, rcDecodeExposureMeterValue(meter(0), Lab.OK, byteArrayOf(0))?.current)
        assertNull(rcDecodeExposureMeterValue(meter(0), Lab.OK, null))
        assertNull(rcDecodeExposureMeterValue(meter(0), Lab.OK, byteArrayOf()))
        assertNull(rcDecodeExposureMeterValue(meter(0), Lab.OK, byteArrayOf(0, 0)))
        assertNull(rcDecodeExposureMeterValue(meter(0), 0x2019, byteArrayOf(0)))
        val alternative = rcDecodeExposureMeterValue(meter(0).copy(prop = NIKON_EXPOSURE_INDICATE), Lab.OK, byteArrayOf(12))
        assertEquals(12L, alternative?.current)
        assertEquals(4f, requireNotNull(rcExposureMeterEv(alternative)), 0f)
    }

    @Test fun delayedOrClockInvalidSamplesAreNeverFresh() {
        assertTrue(rcExposureMeterFresh(100L, 100L))
        assertTrue(rcExposureMeterFresh(100L, 1599L))
        assertFalse(rcExposureMeterFresh(100L, 1600L))
        assertFalse(rcExposureMeterFresh(100L, 99L))
    }
}
