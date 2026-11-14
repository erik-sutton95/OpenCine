package com.opencapture.opencine.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The subnet a Multiview stage looks for cameras on. Swift twin: `StationSubnetTests`. */
class StationSubnetTest {
    @Test
    fun respectsTheActualSubnetAndExcludesActiveCameras() {
        val hosts = StationSubnet.hosts("192.168.7.130", "255.255.255.248", setOf("192.168.7.132"))
        assertEquals(listOf("192.168.7.129", "192.168.7.131", "192.168.7.133", "192.168.7.134"), hosts)
    }

    @Test
    fun crossesOctetsWithoutAssumingSlash24() {
        val hosts = StationSubnet.hosts("10.4.1.10", "255.255.254.0")!!
        assertEquals(509, hosts.size)
        assertEquals("10.4.0.1", hosts.first())
        assertEquals("10.4.1.254", hosts.last())
        assertFalse("10.4.1.10" in hosts)
    }

    @Test
    fun refusesUnboundedMalformedAndNoncontiguousNetworks() {
        for (mask in listOf("255.255.0.0", "255.255.254.128", "255.255.255.255", "255.255.255.254", "bad")) {
            assertNull(StationSubnet.hosts("10.1.2.3", mask), mask)
        }
        assertNull(StationSubnet.hosts("10.1.2.999", "255.255.255.0"))
        assertNull(StationSubnet.hosts("10.1.2.+3", "255.255.255.0"))
        assertEquals(1021, StationSubnet.hosts("10.4.0.1", "255.255.252.0")?.size)
    }

    @Test
    fun aCameraAddressIsUnicastIPv4() {
        for (address in listOf("192.168.1.20", "10.0.0.1", "172.20.10.2", "223.1.1.1")) {
            assertTrue(StationSubnet.validAddress(address), address)
        }
        for (address in listOf("", "0.1.2.3", "127.0.0.1", "224.0.0.1", "255.255.255.255", "1.2.3", "1.2.3.4.5", "a.b.c.d", "1.2.3.256")) {
            assertFalse(StationSubnet.validAddress(address), address)
        }
    }
}
