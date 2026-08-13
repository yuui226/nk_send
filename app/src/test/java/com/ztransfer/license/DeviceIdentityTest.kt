package com.ztransfer.license

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DeviceIdentityTest {
    @Test
    fun `valid android id keeps legacy fingerprint`() {
        assertEquals(
            "171acd97e2a8c42813235fcb73597edc",
            computeDeviceFingerprint("1234567890abcdef", "com.ztransfer", "unused"),
        )
    }

    @Test
    fun `known placeholder android ids fall back to install identity`() {
        assertNull(normalizedAndroidId(null))
        assertNull(normalizedAndroidId(""))
        assertNull(normalizedAndroidId("0000000000000000"))
        assertNull(normalizedAndroidId("9774d56d682e549c"))
    }

    @Test
    fun `zero android id uses private install identity`() {
        val first = computeDeviceFingerprint(
            "0000000000000000", "com.ztransfer", "install-a",
        )
        val second = computeDeviceFingerprint(
            "0000000000000000", "com.ztransfer", "install-b",
        )

        assertNotEquals("793843504c099edbb6c7d97dad20313f", first)
        assertNotEquals(first, second)
    }
}
