package com.opencapture.opencine.streaming

import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull

/** A plain local listener; every wait is on an event, bounded only as a hang guard. */
class StreamConnectionTest {
    private val server = ServerSocket(0, 1, InetAddress.getLoopbackAddress())
    private val events = LinkedBlockingQueue<StreamConnectionEvent>()
    private val connection = SocketStreamConnection("127.0.0.1", server.localPort, tls = false)

    @AfterTest
    fun tearDown() {
        connection.close()
        server.close()
    }

    private fun next(): StreamConnectionEvent = checkNotNull(events.poll(10, TimeUnit.SECONDS)) { "no event" }

    private fun openAndAccept(): Socket {
        connection.open { events.add(it) }
        val peer = server.accept()
        assertEquals(StreamConnectionEvent.Opened, next())
        return peer
    }

    @Test
    fun deliversBytesBothWays() {
        val peer = openAndAccept()
        connection.write(byteArrayOf(1, 2, 3))
        assertEquals(StreamConnectionEvent.Wrote(3), next())
        val read = ByteArray(3)
        peer.getInputStream().readNBytes(read, 0, 3)
        assertContentEquals(byteArrayOf(1, 2, 3), read)
        peer.getOutputStream().apply { write(byteArrayOf(7, 8)); flush() }
        val received = mutableListOf<Byte>()
        while (received.size < 2) received += assertIs<StreamConnectionEvent.Received>(next()).bytes.toList()
        assertEquals(listOf<Byte>(7, 8), received)
        peer.close()
    }

    @Test
    fun reportsWrittenCountsInOrder() {
        val peer = openAndAccept()
        connection.write(ByteArray(10))
        connection.write(ByteArray(200_000))
        assertEquals(StreamConnectionEvent.Wrote(10), next())
        val drain = Thread { peer.getInputStream().readNBytes(200_010) }.apply { start() }
        assertEquals(StreamConnectionEvent.Wrote(200_000), next())
        drain.join()
        peer.close()
    }

    @Test
    fun lostIsReportedOnceAfterPeerCloses() {
        val peer = openAndAccept()
        peer.close()
        assertEquals(StreamConnectionEvent.Lost, next())
        connection.write(ByteArray(4))
        connection.close()
        assertNull(events.poll(200, TimeUnit.MILLISECONDS))
    }

    @Test
    fun refusedConnectionIsLost() {
        val port = server.localPort
        server.close()
        val refused = SocketStreamConnection("127.0.0.1", port, tls = false)
        refused.open { events.add(it) }
        assertEquals(StreamConnectionEvent.Lost, next())
        refused.close()
    }

    @Test
    fun closeReportsNothing() {
        val peer = openAndAccept()
        connection.close()
        assertNull(events.poll(200, TimeUnit.MILLISECONDS))
        peer.close()
    }
}
