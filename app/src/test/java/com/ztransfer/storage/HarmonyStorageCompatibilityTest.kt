package com.ztransfer.storage

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HarmonyStorageCompatibilityTest {
    private fun detect(
        manufacturer: String = "HUAWEI",
        display: String,
        brand: String? = "emui",
        platformVersion: String? = null,
    ) = HarmonyStorageCompatibility.detect(
        manufacturer = manufacturer,
        display = display,
        readOsBrand = { brand },
        readPlatformVersion = { platformVersion },
    )

    @Test
    fun `affected runtime reporting emui is detected from either field build`() {
        for (display in listOf("System 104.5.0.001(SP1C00E1R2P2)", "System 104.3.5.001")) {
            val result = detect(display = display)
            assertTrue(display, result.enabled)
            assertEquals("build-display", result.method)
        }
    }

    @Test
    fun `future harmony runtime builds are detected without a whitelist`() {
        assertTrue(detect(display = "System 105.0.0.100(C00E10R1P1)").enabled)
    }

    @Test
    fun `harmony brand and platform version are detected`() {
        assertEquals("BuildEx.getOsBrand", detect(display = "x", brand = "harmony").method)
        assertEquals("platform-version", detect(display = "x", platformVersion = "4.2.0").method)
    }

    @Test
    fun `brand lookup failure still uses build display`() {
        val result = HarmonyStorageCompatibility.detect(
            manufacturer = "HUAWEI",
            display = "System 104.3.5.001",
            readOsBrand = { throw ClassNotFoundException("BuildEx") },
            readPlatformVersion = { null },
        )
        assertTrue(result.enabled)
        assertTrue(result.error!!.contains("ClassNotFoundException"))
    }

    @Test
    fun `ordinary emui stays on android path but is still huawei`() {
        val result = detect(display = "SLY-AL00 13.0.0.206(C00E200R2P5)")
        assertFalse(result.enabled)
        assertTrue(result.huawei)
    }

    @Test
    fun `non huawei is untouched`() {
        val result = detect(manufacturer = "Xiaomi", display = "System 104.3.5.001")
        assertFalse(result.enabled)
        assertFalse(result.huawei)
    }
}
