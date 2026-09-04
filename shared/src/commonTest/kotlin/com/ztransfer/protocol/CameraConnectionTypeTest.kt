package com.ztransfer.protocol

import kotlin.test.Test
import kotlin.test.assertEquals

class CameraConnectionTypeTest {
    @Test
    fun exposesStableConnectionKindsToEveryPlatform() {
        assertEquals(listOf("WIFI", "USB"), CameraConnectionType.entries.map { it.name })
    }
}
