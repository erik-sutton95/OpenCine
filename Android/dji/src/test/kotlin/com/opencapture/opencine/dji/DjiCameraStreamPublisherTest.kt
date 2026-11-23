package com.opencapture.opencine.dji

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The livestream provisioning sequence over a scripted link; twin of Swift
 * `DJICameraStreamPublisherTests`. SIMULATED: no Bluetooth, every reply scripted, no pause slept.
 */
class DjiCameraStreamPublisherTest {
    private class Link : DjiLivestreamLink {
        val sent = mutableListOf<Pair<Int, String?>>()
        /** Replies per command kind, in order; null is no reply. Missing: `00` (a join `00 00`). */
        val replies = mutableMapOf<Int, ArrayDeque<ByteArray?>>()
        var closed = false

        override suspend fun exchange(kind: Int, extra: String?, timeoutMs: Long): DumlFrame {
            sent += kind to extra
            val queue = replies[kind]
            val payload =
                if (queue.isNullOrEmpty()) {
                    if (kind == DjiNative.CMD_MULTICAM_JOIN) byteArrayOf(0, 0) else byteArrayOf(0)
                } else {
                    queue.removeFirst()
                } ?: throw MultiviewFailure.Timeout()
            return DumlFrame(8, 2, 0, 0x80, 0, 0, payload)
        }

        override suspend fun closeAndWait() {
            closed = true
        }

        val kinds get() = sent.map { it.first }
    }

    private val url = "rtmp://172.20.10.1:1935/live/0123456789abcdef0123456789abcdef"
    private val password = "hunter2-wifi"
    private val log = mutableListOf<String>()
    private val pauses = mutableListOf<Long>()

    private fun publisher(link: Link, pocket3: Boolean = false) =
        DjiCameraStreamPublisher(
            link, pocket3, log = { log += it }, sleep = { pauses += it }, joinPolicy = StationJoin.Policy(),
        )

    private suspend fun DjiCameraStreamPublisher.start(codec: String = "hevc") =
        start(url, "es_iphone16", password, 30, codec)

    private val end = DjiNative.CMD_LIVESTREAM_END
    private val prepare = DjiNative.CMD_LIVESTREAM_PREPARE
    private val join = DjiNative.CMD_MULTICAM_JOIN
    private val configure = DjiNative.CMD_LIVESTREAM_CONFIGURE
    private val start = DjiNative.CMD_LIVESTREAM_START

    @Test
    fun startSendsTheProvenSequence() = runTest {
        val link = Link()
        publisher(link).start()
        assertEquals(listOf(end, prepare, join, configure, start), link.kinds)
        assertEquals("es_iphone16\u001f$password", link.sent[2].second)
        assertEquals("1\u001f$url\u001fhevc\u001f30\u001f6000", link.sent[3].second)
        assertEquals(listOf(1_000L), pauses)
        assertFalse(link.closed)
    }

    @Test
    fun pocket3ConfiguresTheDirectAddress() = runTest {
        val link = Link()
        publisher(link, pocket3 = true).start("h264")
        assertEquals("0\u001f$url\u001fh264\u001f30\u001f6000", link.sent[3].second)
    }

    @Test
    fun joinRetriesOn01FFThenSucceeds() = runTest {
        val link = Link()
        link.replies[join] = ArrayDeque(listOf(byteArrayOf(1, 0xFF.toByte()), byteArrayOf(0, 0)))
        publisher(link).start()
        assertEquals(listOf(end, prepare, join, join, configure, start), link.kinds)
        assertEquals(listOf(1_000L, 5_000L), pauses)
    }

    @Test
    fun aRejectedJoinStopsBeforeConfiguring() = runTest {
        val link = Link()
        link.replies[join] = ArrayDeque(listOf(byteArrayOf(1, 2)))
        val error = assertFailsWith<DjiCameraStreamError.JoinRefused> { publisher(link).start() }
        assertEquals("0102", error.reply)
        assertEquals(listOf(end, prepare, join), link.kinds)
    }

    @Test
    fun startRefusalCarriesTheReply() = runTest {
        val link = Link()
        link.replies[start] = ArrayDeque(listOf(byteArrayOf(0xD6.toByte())))
        val error = assertFailsWith<DjiCameraStreamError.StartRefused> { publisher(link).start() }
        assertEquals("d6", error.reply)
    }

    @Test
    fun aCameraThatStopsAnsweringIsNoReply() = runTest {
        val link = Link()
        link.replies[prepare] = ArrayDeque(listOf(null))
        assertFailsWith<DjiCameraStreamError.NoReply> { publisher(link).start() }
        val quiet = Link()
        quiet.replies[end] = ArrayDeque(listOf(null))
        publisher(quiet).start()
    }

    @Test
    fun endAlwaysClosesTheLink() = runTest {
        val link = Link()
        link.replies[end] = ArrayDeque(listOf(null))
        publisher(link).end()
        assertEquals(listOf(end), link.kinds)
        assertTrue(link.closed)
    }

    @Test
    fun logHoldsNoSecret() = runTest {
        val link = Link()
        val publisher = publisher(link)
        publisher.start()
        publisher.end()
        val text = log.joinToString("\n")
        assertTrue(log.isNotEmpty())
        assertFalse(password in text)
        assertFalse("0123456789abcdef0123456789abcdef" in text)
        assertFalse("01234" in text)
        assertTrue("0123****" in text)
    }
}
