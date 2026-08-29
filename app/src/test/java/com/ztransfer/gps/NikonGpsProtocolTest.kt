package com.ztransfer.gps

import org.junit.Assert.assertEquals
import org.junit.Test

class NikonGpsProtocolTest {
    @Test
    fun matchesCapturedNikonStage2Vector() {
        val first = GpsPairingPacket(
            stage = 1,
            timestamp = 0x677da144ec13e1dbL,
            device = 0x3c3ae501L,
            nonce = 0x3fdaa451L,
        )
        val second = GpsPairingPacket(
            stage = 2,
            timestamp = 0xb9943d5e8026fa29uL.toLong(),
            device = 0xa8b3f2e4L,
            nonce = 0x16d56a13L,
        )
        val third = NikonGpsPairingProtocol().stage3For(first, second)
        assertEquals(0x79f1ad53L, third?.device)
        assertEquals(0x23838a35L, third?.nonce)
    }
}
