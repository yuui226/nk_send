package com.ztransfer.protocol

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFails

class NikonDatasetParserTest {
    @Test
    fun deviceInfoMatchesFixedDataset() {
        val payload = hex(
            "6400EFCDAB8905A0033C5CB75E0000010003000000011028942894" +
                "01000000084002000000015067D000000000010000000138" +
                "064E0069006B006F006E000000" +
                "055A002000330030000000" +
                "0431002E0030000000" +
                "0553004E003DD800DE0000",
        )
        val info = parseDeviceInfo(payload)

        assertEquals("Nikon", info.manufacturer)
        assertEquals("Z 30", info.model)
        assertEquals("1.0", info.deviceVersion)
        assertEquals("SN😀", info.serial)
        assertEquals(0x89ABCDEFL, info.vendorExtId)
        assertEquals(0xA005, info.vendorExtVersion)
        assertEquals("尼康", info.vendorExtDesc)
        assertEquals(listOf(0x1001, 0x9428), info.operations.toList())
        assertEquals(setOf(0x4008), info.events)
        assertEquals(setOf(0x5001, 0xD067), info.props)

        payload.indices.forEach { endExclusive ->
            assertFails("prefix length $endExclusive should fail") {
                parseDeviceInfo(payload.copyOf(endExclusive))
            }
        }
        assertEquals(info, parseDeviceInfo(payload + byteArrayOf(0x7F)))

        val unterminatedSerial = payload.copyOf().also {
            it[it.lastIndex - 1] = 'X'.code.toByte()
        }
        assertEquals("SN😀X", parseDeviceInfo(unterminatedSerial).serial)
    }

    @Test
    fun legacyAndExtendedEventsMatchExistingShapes() {
        assertEquals(
            listOf(0x4002 to 0x291961F6L),
            parseNikonEvents(hex("01000240F6611929")),
        )
        assertEquals(
            listOf(0x4002 to 0x291961F6L, 0x400D to 0L),
            parseNikonExtendedEvents(
                hex("0200000002400200F6611929010001000D400000"),
            ),
        )
    }

    @Test
    fun malformedEventsKeepThrowing() {
        assertFails {
            parseNikonExtendedEvents(hex("0100000002400100"))
        }
        assertFails {
            parseNikonExtendedEvents(hex("0100000002400600") + ByteArray(24))
        }
        assertFails {
            parseNikonEvents(hex("01000240"))
        }
    }

    @Test
    fun vendorCodesStay32BitAndRejectFalseCounts() {
        assertEquals(
            setOf(0xD1A3, 0x1D033, 0xD1BD),
            parseVendorCodes32(hex("03000000A3D1000033D00100BDD10000")),
        )
        assertFails {
            parseVendorCodes32(hex("0200000033D00100"))
        }
    }

    @Test
    fun truncatedDeviceInfoStillFailsInsteadOfReturningPartialCapabilities() {
        assertFails { parseDeviceInfo(byteArrayOf()) }
        assertFails { parseDeviceInfo(hex("64000A00000064000100")) }
        assertFails {
            parseDeviceInfo(hex("64000A0000006400000000FFFFFFFF"))
        }

        assertEquals(
            "\uFFFDX\uFFFD",
            hex("00D8580000DC").decodeUtf16LittleEndian(offset = 0, codeUnits = 3),
        )
    }

    private fun hex(value: String): ByteArray {
        require(value.length % 2 == 0)
        return ByteArray(value.length / 2) { index ->
            value.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }
}
