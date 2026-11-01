package com.opencapture.opencine.insta360.luna

import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlinx.coroutines.runBlocking

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
}
