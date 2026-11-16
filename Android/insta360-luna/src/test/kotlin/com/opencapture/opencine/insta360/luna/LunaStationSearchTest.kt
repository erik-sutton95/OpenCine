package com.opencapture.opencine.insta360.luna

import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import com.opencapture.opencine.core.ConnectionFailure

/** Finding a camera in station role: only a host answering the preface with UCD2 is the camera. */
class LunaStationSearchTest {
    private val servers = mutableListOf<ServerSocket>()

    @AfterTest fun close() { servers.forEach { runCatching { it.close() } } }

    /** A local control port that reads the preface and answers [reply]. */
    private fun server(reply: ByteArray, prefaces: MutableList<ByteArray> = mutableListOf()): Int {
        val server = ServerSocket(0, 8, InetAddress.getLoopbackAddress()).also(servers::add)
        thread(isDaemon = true) {
            while (!server.isClosed) {
                val client = runCatching { server.accept() }.getOrNull() ?: break
                client.use {
                    val preface = ByteArray(LunaWire.prefix.size)
                    var read = 0
                    while (read < preface.size) { val count = it.getInputStream().read(preface, read, preface.size - read); if (count < 0) break; read += count }
                    synchronized(prefaces) { prefaces += preface }
                    it.getOutputStream().apply { write(reply); flush() }
                    Thread.sleep(200)
                }
            }
        }
        return server.localPort
    }

    @Test fun theCameraIsTheHostAnsweringTheGreeting() = runBlocking {
        val prefaces = mutableListOf<ByteArray>()
        val port = server("UCD2".toByteArray() + ByteArray(12), prefaces)
        val found = LunaStationSearch.find(listOf("127.0.0.1"), port, LunaWire.prefix, budgetMs = 5_000, open = ::Socket, isCurrent = { true })
        assertEquals("127.0.0.1", found)
        assertEquals(LunaWire.prefix.toList(), synchronized(prefaces) { prefaces.first().toList() })
    }

    @Test fun aHostAnsweringSomethingElseIsNotTheCamera() = runBlocking {
        val port = server("HTTP/1.1 400".toByteArray())
        assertNull(LunaStationSearch.find(listOf("127.0.0.1"), port, LunaWire.prefix, budgetMs = 1_500, open = ::Socket, isCurrent = { true }))
    }

    @Test fun noHostAnsweringMeansNoCamera() = runBlocking {
        val port = ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { it.localPort }
        assertNull(LunaStationSearch.find(listOf("127.0.0.1"), port, LunaWire.prefix, budgetMs = 1_500, open = ::Socket, isCurrent = { true }))
    }

    // Several cameras on one network (multicam over a router or hotspot): the connect must end on
    // the camera it asked for, never on whichever camera answered first. Virtual time only.

    /** A router's /24 around the phone at .20, nearest first: `.21` is searched in the first batch, `.200` later. */
    private val router = LunaStationWire.candidates("192.168.1.20", 24)
    private val anotherCamera = LunaStationFailure(LunaDeviceIdentity.mismatch(ByteArray(0), "requested")!!)

    private fun findsTheRequestedCamera(requested: String, other: String) = runTest {
        val opened = mutableListOf<String>()
        val host = LunaStationSearch.findRequested(
            router, budgetMs = 60_000, excluding = emptySet(), isCurrent = { true }, nowMs = { testScheduler.currentTime },
            probe = { it == requested || it == other },
        ) { host ->
            opened += host
            if (host != requested) throw anotherCamera
        }
        assertEquals(requested, host)
        assertTrue(opened.count { it == other } <= 1, "a camera that is not the requested one is opened once at most")
    }

    @Test fun theRequestedCameraIsFoundWhicheverCameraAnswersFirst() {
        findsTheRequestedCamera(requested = "192.168.1.200", other = "192.168.1.21")
        findsTheRequestedCamera(requested = "192.168.1.21", other = "192.168.1.200")
    }

    @Test fun aHostAnotherConnectionHoldsIsNeverProbed() = runTest {
        val probed = mutableSetOf<String>()
        val hotspot = listOf("172.20.10.9") + LunaStationWire.candidates("172.20.10.1", 28).filter { it != "172.20.10.9" }
        val host = LunaStationSearch.findRequested(
            hotspot, budgetMs = 60_000, excluding = setOf("172.20.10.9"), isCurrent = { true },
            nowMs = { testScheduler.currentTime },
            probe = { probed += it; it == "172.20.10.9" || it == "172.20.10.4" },
        ) {}
        assertEquals("172.20.10.4", host)
        assertFalse("172.20.10.9" in probed)
    }

    @Test fun onlyAnotherCameraOnTheNetworkEndsAsNotFoundWhenTheSearchTimeRunsOut() = runTest {
        val opened = mutableListOf<String>()
        val host = LunaStationSearch.findRequested(
            LunaStationWire.candidates("172.20.10.1", 28), budgetMs = 100, excluding = emptySet(), isCurrent = { true },
            nowMs = { testScheduler.currentTime },
            probe = { delay(10); it == "172.20.10.9" },
        ) { host ->
            opened += host
            throw anotherCamera
        }
        assertNull(host)
        assertEquals(listOf("172.20.10.9"), opened, "the other camera is not opened again")
    }

    @Test fun aFailureOtherThanAnotherCameraEndsTheSearch() = runTest {
        val lost = LunaStationFailure(LunaFailures.failure(ConnectionFailure.Reason.LinkLost, "link.dropped", "lost"))
        val thrown = runCatching {
            LunaStationSearch.findRequested(
                LunaStationWire.candidates("172.20.10.1", 28), budgetMs = 60_000, excluding = emptySet(),
                isCurrent = { true }, nowMs = { testScheduler.currentTime }, probe = { it == "172.20.10.9" },
            ) { throw lost }
        }.exceptionOrNull()
        assertEquals(lost, thrown)
    }
}
