package com.opencapture.opencine.streaming

import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The Android listener over loopback with a scripted receive session; twin of Swift
 * `RTMPLocalReceiverTests`. A connection that writes `good` publishes under the key, `bad` is a
 * wrong key, and anything else says nothing yet. SIMULATED session, real sockets.
 */
class RtmpLocalReceiverTest {
    private class Native : StreamingNativeApi by FakeStreamingNative() {
        private var next = 0

        override fun receiverCreate(token: String): String = synchronized(this) { "peer-${next++}" }

        override fun receiverFeed(owner: String, bytes: ByteArray): ByteArray {
            val text = String(bytes)
            return when {
                text.startsWith("good") -> reply(1 to ByteArray(0), 9 to ByteArray(0))
                text.startsWith("bad") -> reply(7 to "unexpectedStreamKey".toByteArray(), 10 to ByteArray(0))
                text.startsWith("frame") -> reply(9 to ByteArray(0))
                else -> reply()
            }
        }

        override fun receiverClose(owner: String) {}

        private fun reply(vararg events: Pair<Int, ByteArray>): ByteArray {
            val buffer = ByteBuffer.allocate(6 + events.sumOf { 5 + it.second.size })
            buffer.putInt(0).putShort(events.size.toShort())
            for ((kind, body) in events) buffer.put(kind.toByte()).putInt(body.size).put(body)
            return buffer.array()
        }
    }

    private val events = CopyOnWriteArrayList<RtmpLocalReceiver.Event>()
    private val published = CountDownLatch(1)
    private val gone = CountDownLatch(1)

    private fun receiver(windowMs: Long = 10_000): RtmpLocalReceiver {
        val port = (50_000..60_000).random()
        return RtmpLocalReceiver(port, "key", Native(), windowMs) { event ->
            events += event
            if (event is RtmpLocalReceiver.Event.PublisherConnected) published.countDown()
            if (event is RtmpLocalReceiver.Event.PublisherDisconnected) gone.countDown()
        }.also { it.start() }
    }

    private fun port() = (events.first() as RtmpLocalReceiver.Event.Listening).port

    @Test
    fun strangersNeverDisplaceThePublisher() {
        val receiver = receiver()
        try {
            val camera = Socket("127.0.0.1", port()).apply { getOutputStream().write("good".toByteArray()) }
            assertTrue(published.await(5, TimeUnit.SECONDS))
            val silent = Socket("127.0.0.1", port())
            val stranger = Socket("127.0.0.1", port()).apply { getOutputStream().write("bad".toByteArray()) }
            assertEquals(-1, stranger.getInputStream().read(), "The wrong key is closed")
            camera.getOutputStream().write("frame".toByteArray())
            Thread.sleep(300)
            assertEquals(1, events.count { it is RtmpLocalReceiver.Event.PublisherConnected })
            assertTrue(events.none { it is RtmpLocalReceiver.Event.PublisherDisconnected })
            assertEquals(2, events.count { it == RtmpLocalReceiver.Event.Session(RtmpReceiveEvent.VideoEnd) })
            camera.close()
            assertTrue(gone.await(5, TimeUnit.SECONDS))
            silent.close()
        } finally {
            receiver.stop()
        }
    }

    @Test
    fun aSilentCandidateIsClosedAfterTheWindow() {
        val receiver = receiver(windowMs = 200)
        try {
            val silent = Socket("127.0.0.1", port()).apply { soTimeout = 5_000 }
            assertEquals(-1, silent.getInputStream().read())
            assertTrue(events.none { it is RtmpLocalReceiver.Event.PublisherConnected })
        } finally {
            receiver.stop()
        }
    }
}
