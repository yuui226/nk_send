package com.ztransfer.connection

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class NativeCameraEndpointAddressTest {
    @Test fun normalizesExplicitHostsWithoutResolution() {
        mapOf(" 192.168.1.2 " to "192.168.1.2", "NIKON.local." to "nikon.local", "camera-1" to "camera-1",
            "[FE80::1%en0]" to "fe80::1%en0", "2001:DB8:0:0:0:0:0:1" to "2001:db8:0:0:0:0:0:1",
            "::ffff:192.168.1.2" to "::ffff:192.168.1.2", "::1" to "::1").forEach { (raw, expected) ->
            assertEquals(expected, NativeCameraEndpointAddress.normalize(raw), raw)
        }
    }
    @Test fun rejectsSchemesPortsMalformedAddressesAndAmbiguousNumericHosts() {
        listOf("", " ", "http://camera.local", "camera:15740", "192.168.1.2:15740", "[::1]:15740", "user@camera",
            "camera/path", "camera?x", "camera#x", "camera\\share", "a b", "相机.local", "camera..local",
            "-camera", "camera-", "a_1.local", "192.168.1", "256.1.1.1", "01.2.3.4", "42", "[camera]",
            "1:2:3", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9", "1::2::3", "1:::2", "::ffff:999.1.1.1",
            "1:2:3:4:5:6:7::8", "::1%", "::1%en0%en1", "camera%en0", "[::1", "::1]", "a".repeat(64) + ".local")
            .forEach { assertNull(NativeCameraEndpointAddress.normalize(it), it) }
    }
    @Test fun ipv4TailMustBeTheActualFinalIpv6Component() {
        assertNull(NativeCameraEndpointAddress.normalize("192.168.1.2::"))
        assertNull(NativeCameraEndpointAddress.normalize("::192.168.1.2:1"))
        assertEquals("1:2:3:4:5:6:192.168.1.2", NativeCameraEndpointAddress.normalize("1:2:3:4:5:6:192.168.1.2"))
    }
}
