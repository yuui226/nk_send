package com.ztransfer.gps

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Sanitized Z30 responses and synthetic edge cases; parser tests do not prove STA support. */
class BleControlProbeProtocolTest {
    @Test
    fun z30V120CaptureAdvertisesSelectorButNotMenu() {
        // 2026-10-23: real Z30 V1.20 replies after remoteMode(true) was acknowledged.
        val feature = parse(bytes(0x0c, 0, 1, 1, 1, 1, 3, 0, 7, 0, 0, 0))
        val configuration = parse(bytes(8, 0, 0x10, 1, 0xee, 1, 0, 0))
        assertEquals(true, feature.remoteControl)
        assertTrue(feature.details.contains("remoteFlags=0x0003"))
        assertTrue(feature.details.contains("shootingFlags=0x0007"))
        assertEquals(false, configuration.menu)
        assertEquals(true, configuration.selector)
        assertEquals(true, configuration.keyEvents)
        assertEquals(1, configuration.responseCode)
    }

    @Test
    fun encodesQueriesAndRemoteSessionWithoutNetworkModeClaims() {
        assertArrayEquals(bytes(4, 0, 1, 0), BleControlProbeProtocol.featureQuery())
        assertArrayEquals(bytes(4, 0, 0x10, 0), BleControlProbeProtocol.configurationQuery())
        assertArrayEquals(bytes(5, 0, 0x11, 0, 1), BleControlProbeProtocol.remoteMode(true))
        assertArrayEquals(bytes(5, 0, 0x11, 0, 0), BleControlProbeProtocol.remoteMode(false))
        BleControlProbeProtocol.featureQuery()[2] = 0
        assertEquals(1, BleControlProbeProtocol.featureQuery()[2].toInt())
    }

    @Test
    fun allowsOnlyMenuAndSelectorKeyPressesAndReleases() {
        val allowed = setOf(5, 7, 8, 9, 10, 11)
        for (key in -1..256) {
            if (key in allowed) {
                assertArrayEquals(bytes(6, 0, 0x12, 0, key, 1), BleControlProbeProtocol.key(key, true))
                assertArrayEquals(bytes(6, 0, 0x12, 0, key, 0), BleControlProbeProtocol.key(key, false))
            } else {
                try {
                    BleControlProbeProtocol.key(key, true)
                    fail("Unexpectedly accepted key $key")
                } catch (_: IllegalArgumentException) {
                    // Includes power, shutter, movie, playback, zoom and volume keys.
                }
            }
        }
        for (key in listOf(Int.MIN_VALUE, Int.MAX_VALUE, 0x105)) {
            try {
                BleControlProbeProtocol.key(key, false)
                fail("Must validate before converting $key to a byte")
            } catch (_: IllegalArgumentException) {
            }
        }
    }

    @Test
    fun parsesFeatureVariantsWithoutInventingKeyEventSupport() {
        val unsupported = parse(packet(1, 1, 0, 0))
        assertEquals(false, unsupported.remoteControl)
        assertNull(unsupported.keyEvents)
        assertNull(unsupported.menu)

        val remote = parse(packet(1, 1, 1, 1, 0, 0))
        assertEquals(true, remote.remoteControl)
        assertNull(remote.keyEvents)
        assertTrue(remote.details.contains("remoteFlags=0x0000"))

        val shooting = parse(packet(1, 1, 3, 1, 2, 0, 7, 0))
        assertTrue(shooting.details.contains("shootingFlags=0x0007"))
        assertNull(shooting.keyEvents)
        assertNull(shooting.selector)
    }

    @Test
    fun rejectsMissingRequiredAndConditionalFeatureFields() {
        val fixtures = listOf(
            packet(1, 1, 0, 0),
            packet(1, 1, 1, 1, 0, 0),
            packet(1, 1, 1, 1, 2, 0, 7, 0),
        )
        for (fixture in fixtures) {
            for (size in 4 until fixture.size) {
                // Also correct the advertised length: this tests field validation, not just framing.
                val truncated = fixture.copyOf(size).also { it[0] = size.toByte() }
                assertNull("size=$size fixtureSize=${fixture.size}", BleControlProbeProtocol.parseResponse(truncated))
            }
        }
    }

    @Test
    fun configurationBitsAreIndependentOfPowerAndOfEachOther() {
        for (menu in listOf(false, true)) {
            for (selector in listOf(false, true)) {
                val flags = (if (menu) 0x10 else 0) or (if (selector) 0x40 else 0)
                val result = parse(packet(0x10, 1, flags, 0, 0, 0))
                assertEquals(menu, result.menu)
                assertEquals(selector, result.selector)
                assertEquals(menu || selector, result.keyEvents)
                assertNull(result.remoteControl)
            }
        }
        val otherKeysOnly = parse(packet(0x10, 1, 0xaf, 1, 0, 0))
        assertEquals(false, otherKeysOnly.keyEvents)
        val unsignedFlags = parse(packet(0x10, 1, 0x50, 0, 0, 0x80))
        assertTrue(unsignedFlags.details.contains("flags=0x80000050"))
        for (size in 4..7) {
            assertNull(BleControlProbeProtocol.parseResponse(bytes(size, 0, 0x10, 1).copyOf(size)))
        }
    }

    @Test
    fun rejectsBadFramingUnknownOperationsAndUnknownResponseCodes() {
        for (size in 0..3) assertNull(BleControlProbeProtocol.parseResponse(ByteArray(size)))
        assertNull(BleControlProbeProtocol.parseResponse(bytes(3, 0, 0x11, 1)))
        assertNull(BleControlProbeProtocol.parseResponse(bytes(5, 0, 0x11, 1)))
        assertNull(BleControlProbeProtocol.parseResponse(bytes(0xff, 0xff, 0x11, 1)))
        assertNull(BleControlProbeProtocol.parseResponse(ByteArray(0x10000)))
        for (op in listOf(0, 2, 0x0f, 0x13, 0x80, 0xff)) {
            assertNull(BleControlProbeProtocol.parseResponse(packet(op, 1)))
        }
        for (code in listOf(0, 6, 0x7e, 0x80, 0xff)) {
            assertNull(BleControlProbeProtocol.parseResponse(packet(0x11, code)))
        }
    }

    @Test
    fun failedResponsesNeverSupplyCapabilities() {
        for (op in listOf(1, 0x10, 0x11, 0x12)) {
            for (code in listOf(2, 3, 4, 5, 0x7f)) {
                for (fixture in listOf(packet(op, code), packet(op, code, 0xff, 0xff, 0xff, 0xff))) {
                    val result = parse(fixture)
                    assertEquals(code, result.responseCode)
                    assertNull(result.remoteControl)
                    assertNull(result.keyEvents)
                    assertNull(result.menu)
                    assertNull(result.selector)
                    assertFalse(result.details.contains("SUCCESS"))
                }
            }
        }
    }

    @Test
    fun acceptsKnownPrefixesAndReportsUninterpretedExtensionBytes() {
        for (op in listOf(0x11, 0x12)) {
            val result = parse(packet(op, 1))
            assertEquals(op, result.opcode)
            assertEquals(1, result.responseCode)
            assertNull(result.keyEvents)
        }
        assertTrue(parse(packet(0x11, 1, 0x99)).details.contains("extraBytes=1"))
        assertTrue(parse(packet(0x10, 1, 0x50, 0, 0, 0, 0x99)).details.contains("extraBytes=1"))
        assertTrue(parse(packet(1, 1, 0, 0, 0x99)).details.contains("extraBytes=1"))
    }

    @Test
    fun statusReportsTruncationAndUnknownValuesWithoutCallingThemNormal() {
        for (size in 0..4) {
            assertTrue(BleControlProbeProtocol.describeStatus(ByteArray(size)).startsWith("invalid status"))
        }
        for ((value, label) in listOf("NOT_CONTROL", "PHOTO", "PLAY", "MENU").withIndex()) {
            val status = BleControlProbeProtocol.describeStatus(bytes(value, 0, 0, 0, 0))
            assertTrue(status.contains("state=$label"))
        }
        val unknown = BleControlProbeProtocol.describeStatus(bytes(0xff, 0xfe, 0xfd, 0xfc, 0xfb, 0xfa))
        assertTrue(unknown.contains("UNKNOWN(0xff)"))
        assertTrue(unknown.contains("sub=0xfe"))
        assertTrue(unknown.contains("extraBytes=1"))
        assertFalse(unknown.contains("PHOTO"))
    }

    private fun parse(bytes: ByteArray): ControlProbeResponse {
        val result = BleControlProbeProtocol.parseResponse(bytes)
        assertNotNull(result)
        return requireNotNull(result)
    }

    private fun packet(op: Int, code: Int, vararg payload: Int): ByteArray =
        bytes(payload.size + 4, 0, op, code, *payload)

    private fun bytes(vararg values: Int): ByteArray = values.map { it.toByte() }.toByteArray()
}
