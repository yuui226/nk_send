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

    @Test
    fun `pinned fingerprint wins over token and current platform identity`() {
        assertEquals(
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            selectDeviceFingerprint(
                pinnedFingerprint = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                signedTokenFingerprint = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                currentFingerprint = { error("platform identity should not be read") },
            ),
        )
    }

    @Test
    fun `signed token migrates an existing installation before platform identity`() {
        assertEquals(
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            selectDeviceFingerprint(
                pinnedFingerprint = "corrupt",
                signedTokenFingerprint = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                currentFingerprint = { error("platform identity should not be read") },
            ),
        )
    }

    @Test
    fun `new installation pins the current platform identity`() {
        assertEquals(
            "cccccccccccccccccccccccccccccccc",
            selectDeviceFingerprint(
                pinnedFingerprint = null,
                signedTokenFingerprint = null,
                currentFingerprint = { "cccccccccccccccccccccccccccccccc" },
            ),
        )
    }
}
