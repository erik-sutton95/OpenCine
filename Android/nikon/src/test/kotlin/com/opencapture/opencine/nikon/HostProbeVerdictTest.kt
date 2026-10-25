package com.opencapture.opencine.nikon

import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.PortUnreachableException
import java.net.SocketException
import java.net.SocketTimeoutException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** A failed connect's verdict comes from its errno, not from the exception type alone. */
class HostProbeVerdictTest {
    private fun android(errno: String, text: String) =
        ConnectException(
            "failed to connect to /192.168.1.20 (port 15741) from /192.168.1.21 (port 40112) after 1500ms: " +
                "isConnected failed: $errno ($text)",
        )

    @Test
    fun `a late no route from a dozing body is silence, never a refusal`() {
        // Hardware pass 2026-10-25, 3.7: Android raised this as a ConnectException, and the
        // liveness dial read it as a refusal, so a silent body counted as occupied.
        val verdict = HostProbeVerdict.ofDialFailure(android("EHOSTUNREACH", "No route to host"))
        assertEquals(HostProbeVerdict.NO_ROUTE, verdict)
        assertFalse(verdict.isOccupied)
        assertTrue(verdict.isSilence)
        assertEquals(HostProbeVerdict.NO_ROUTE, HostProbeVerdict.ofDialFailure(android("EHOSTDOWN", "Host is down")))
    }

    @Test
    fun `only a refusal proves an occupied address`() {
        assertEquals(HostProbeVerdict.REFUSED, HostProbeVerdict.ofDialFailure(android("ECONNREFUSED", "Connection refused")))
        assertEquals(HostProbeVerdict.REFUSED, HostProbeVerdict.ofDialFailure(ConnectException("Connection refused")))
        assertEquals(HostProbeVerdict.REFUSED, HostProbeVerdict.ofDialFailure(PortUnreachableException()))
        assertTrue(HostProbeVerdict.ofDialFailure(ConnectException("Connection refused")).isOccupied)
    }

    @Test
    fun `timeouts, unreachable networks and permission refusals keep their own verdicts`() {
        assertEquals(HostProbeVerdict.TIMEOUT, HostProbeVerdict.ofDialFailure(SocketTimeoutException("connect timed out")))
        assertEquals(HostProbeVerdict.TIMEOUT, HostProbeVerdict.ofDialFailure(android("ETIMEDOUT", "Connection timed out")))
        assertEquals(HostProbeVerdict.NO_ROUTE, HostProbeVerdict.ofDialFailure(NoRouteToHostException("Host unreachable")))
        assertEquals(HostProbeVerdict.NO_NETWORK, HostProbeVerdict.ofDialFailure(android("ENETUNREACH", "Network is unreachable")))
        assertEquals(HostProbeVerdict.DENIED, HostProbeVerdict.ofDialFailure(SocketException("socket failed: EACCES (Permission denied)")))
        assertEquals(HostProbeVerdict.NO_NETWORK, HostProbeVerdict.ofDialFailure(SocketException("Socket closed")))
        assertEquals(HostProbeVerdict.UNREACHABLE_OTHER, HostProbeVerdict.ofDialFailure(ConnectException("failed")))
        assertEquals(HostProbeVerdict.UNREACHABLE_OTHER, HostProbeVerdict.ofDialFailure(IOException("too many open files")))
    }

    @Test
    fun `the errno is found on a wrapped cause too`() {
        val wrapped = ConnectException("failed to connect").apply { initCause(IOException("connect failed: ECONNREFUSED (Connection refused)")) }
        assertEquals(HostProbeVerdict.REFUSED, HostProbeVerdict.ofDialFailure(wrapped))
    }
}
