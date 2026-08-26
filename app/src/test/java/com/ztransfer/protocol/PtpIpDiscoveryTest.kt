package com.ztransfer.protocol

import java.net.Inet4Address
import java.net.InetAddress
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PtpIpDiscoveryTest {
    @Test
    fun broadLanKeepsItsRouteWhileLimitingActiveScanToLocalSlash24() {
        assertEquals(24, effectivePtpScanPrefix(16))
        assertEquals(24, effectivePtpScanPrefix(24))
        assertEquals(26, effectivePtpScanPrefix(26))

        val phone = ipv4("192.168.10.20")
        assertTrue(ipv4SubnetContains(phone, "192.168.80.30", 16))
        assertFalse(ipv4SubnetContains(phone, "192.168.80.30", 24))
    }

    @Test
    fun routeMembershipRejectsSelfInvalidAndOutsideAddresses() {
        val phone = ipv4("10.20.30.40")
        assertFalse(ipv4SubnetContains(phone, "10.20.30.40", 16))
        assertFalse(ipv4SubnetContains(phone, "10.21.30.40", 16))
        assertFalse(ipv4SubnetContains(phone, "not-an-ip", 16))
        assertFalse(ipv4SubnetContains(phone, "10.20.30.50", 40))
    }

    private fun ipv4(value: String): Inet4Address =
        InetAddress.getByName(value) as Inet4Address
}
