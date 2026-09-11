package com.ztransfer.protocol

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PtpIpDiscoveryPolicyTest {
    @Test
    fun broadLanKeepsRouteMembershipWhileActiveScanIsBounded() {
        assertEquals(24, effectivePtpScanPrefix(16))
        assertEquals(24, effectivePtpScanPrefix(24))
        assertEquals(26, effectivePtpScanPrefix(26))
        assertEquals(24, effectivePtpScanPrefix(-1))
        assertEquals(32, effectivePtpScanPrefix(40))

        assertTrue(ipv4SubnetContains("192.168.10.20", "192.168.80.30", 16))
        assertFalse(ipv4SubnetContains("192.168.10.20", "192.168.80.30", 24))
        assertTrue(ipv4SubnetContains("192.168.10.20", "192.168.10.0", 24))
        assertTrue(ipv4SubnetContains("192.168.10.20", "192.168.10.255", 24))
    }

    @Test
    fun routeMembershipRejectsSelfInvalidAndOutsideAddresses() {
        assertFalse(ipv4SubnetContains("10.20.30.40", "10.20.30.40", 16))
        assertFalse(ipv4SubnetContains("10.20.30.40", "10.21.30.40", 16))
        assertFalse(ipv4SubnetContains("10.20.30.40", "not-an-ip", 16))
        assertFalse(ipv4SubnetContains("not-an-ip", "10.20.30.50", 16))
        assertFalse(ipv4SubnetContains("10.20.30.40", "10.20.30.50", 40))
        assertFalse(ipv4SubnetContains("10.20.30.40", "10.20.30.256", 16))
        assertFalse(ipv4SubnetContains("10.20.30.40", "10.20..50", 16))
        assertFalse(ipv4SubnetContains("10.20.30.40", " 10.20.30.50", 16))
        assertTrue(ipv4SubnetContains("1.2.3.5", "+1.2.3.4", 24))
        assertTrue(ipv4SubnetContains("10.20.30.40", "172.16.1.2", 0))
        assertFalse(ipv4SubnetContains("10.20.30.40", "10.20.30.40", 0))
    }

    @Test
    fun subnetKeysNormalizeAcceptedIpv4Text() {
        assertEquals("192.168.10.0/24", ipv4SubnetKey("192.168.10.20", 24))
        assertEquals("10.20.0.0/16", ipv4SubnetKey("010.020.030.040", 16))
        assertNull(ipv4SubnetKey("10.20.30", 24))
        assertNull(ipv4SubnetKey("10.20.30.40", 33))
    }

    @Test
    fun scanHostsExcludeNetworkBroadcastAndLocalInAscendingOrder() {
        assertEquals(
            listOf("192.168.10.2"),
            ipv4ScanHosts("192.168.10.1", 30),
        )
        assertEquals(
            listOf("192.168.10.1"),
            ipv4ScanHosts("192.168.10.2", 30),
        )
        val slash24 = ipv4ScanHosts("192.168.10.20", 24)
        assertEquals(253, slash24.size)
        assertEquals("192.168.10.1", slash24.first())
        assertEquals("192.168.10.254", slash24.last())
        assertFalse("192.168.10.20" in slash24)
    }

    @Test
    fun oversizedOrInvalidRangesAreNotActivelyScanned() {
        assertTrue(ipv4ScanHosts("192.168.10.20", 23).isEmpty())
        assertTrue(ipv4ScanHosts("bad", 24).isEmpty())
        assertTrue(ipv4ScanHosts("192.168.10.20", 33).isEmpty())
        assertTrue(ipv4ScanHosts("192.168.10.20", 31).isEmpty())
    }
}
