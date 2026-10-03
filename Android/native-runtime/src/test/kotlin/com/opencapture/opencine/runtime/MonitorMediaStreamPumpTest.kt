package com.opencapture.opencine.runtime

import com.opencapture.opencine.media.MediaByteSink
import com.opencapture.opencine.media.MediaTransferReceipt
import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.*

/** SIMULATED native HTTP driver. Manual gates prove completion/cancellation without clocks or sockets. */
class MonitorMediaStreamPumpTest {
    private class Sink : MediaByteSink {
        private val output = ByteArrayOutputStream()
        override suspend fun write(chunk: ByteArray) { synchronized(output) { output.write(chunk) } }
        fun bytes(): ByteArray = synchronized(output) { output.toByteArray() }
    }
    private class Source(val bytes: ByteArray, val header: Long? = null, val code: Int = 200,
        val eof: Boolean = true) : MonitorMediaReadSource {
        val cancelled = AtomicBoolean(false)
        val closed = AtomicBoolean(false)
        val reads = AtomicInteger(0)
        override fun cancel() { cancelled.set(true) }
        override fun open() = object : MonitorMediaReadStream {
            override val status = code
            override val contentLength = header
            override val input = object : InputStream() {
                private var offset = 0
                override fun read(): Int {
                    val buffer = ByteArray(1)
                    return if (read(buffer, 0, 1) < 0) -1 else buffer[0].toInt() and 255
                }
                override fun read(target: ByteArray, off: Int, len: Int): Int {
                    reads.incrementAndGet()
                    if (offset == bytes.size) {
                        check(eof) { "A complete response must not perform another blocking read" }
                        return -1
                    }
                    val count = minOf(len, bytes.size - offset)
                    bytes.copyInto(target, off, offset, offset + count); offset += count
                    return count
                }
            }
            override fun close() { closed.set(true) }
        }
    }
    private class BlockingSource(val holdOpen: Boolean) : MonitorMediaReadSource {
        val entered = CompletableDeferred<Unit>()
        val cancelled = AtomicBoolean(false)
        val closed = AtomicBoolean(false)
        private val release = CountDownLatch(1)
        override fun cancel() { cancelled.set(true); release.countDown() }
        private fun block(): Nothing {
            entered.complete(Unit); release.await(); throw IOException("Cancelled native request")
        }
        override fun open(): MonitorMediaReadStream {
            if (holdOpen) block()
            return object : MonitorMediaReadStream {
                override val status = 200
                override val contentLength: Long? = null
                override val input = object : InputStream() {
                    override fun read(): Int = block()
                    override fun read(target: ByteArray, off: Int, len: Int): Int = block()
                }
                override fun close() { closed.set(true) }
            }
        }
    }
    @Test fun headerLengthWinsAndClosesWithoutEOF() = runTest {
        val source = Source(byteArrayOf(1, 2), header = 2, eof = false); val sink = Sink()
        assertEquals(MediaTransferReceipt(2, 2), MonitorMediaStreamPump().transfer(source, 9, sink))
        assertContentEquals(byteArrayOf(1, 2), sink.bytes())
        assertEquals(1, source.reads.get()); assertTrue(source.cancelled.get()); assertTrue(source.closed.get())
    }
    @Test fun sourceHintStopsBodyWhenHeaderUnknown() = runTest {
        val source = Source(byteArrayOf(3, 4), eof = false)
        assertEquals(MediaTransferReceipt(2, 2), MonitorMediaStreamPump().transfer(source, 2, Sink()))
        assertEquals(1, source.reads.get())
    }
    @Test fun positiveEOFDoesNotInventSizeOrRejectPartialReceipt() = runTest {
        for (hint in listOf(null, 9L)) {
            val source = Source(byteArrayOf(5, 6))
            assertEquals(MediaTransferReceipt(2, hint), MonitorMediaStreamPump().transfer(source, hint, Sink()))
        }
    }
    @Test fun emptyEOFIsRefused() = runTest {
        assertFailsWith<MonitorMediaStreamException.Empty> { MonitorMediaStreamPump().transfer(Source(byteArrayOf()), sink = Sink()) }
    }
    @Test fun cancellationRetiresPendingReadAndItsNativeRequest() = runTest {
        val source = BlockingSource(false); val sink = Sink()
        val task = async { MonitorMediaStreamPump().transfer(source, sink = sink) }
        source.entered.await(); task.cancelAndJoin()
        assertTrue(source.cancelled.get()); assertTrue(source.closed.get()); assertTrue(sink.bytes().isEmpty())
    }
    @Test fun cancellationRetiresPendingOpenAndItsNativeRequest() = runTest {
        val source = BlockingSource(true)
        val task = async { MonitorMediaStreamPump().transfer(source, sink = Sink()) }
        source.entered.await(); task.cancelAndJoin()
        assertTrue(source.cancelled.get())
    }
    @Test fun refusedStatusAndOversizedBodyCannotComplete() = runTest {
        val source = Source(byteArrayOf(1), code = 403); val sink = Sink()
        assertEquals(403, assertFailsWith<MonitorMediaStreamException.Status> {
            MonitorMediaStreamPump().transfer(source, sink = sink)
        }.status)
        assertEquals(0, source.reads.get()); assertTrue(sink.bytes().isEmpty())
        assertFailsWith<MonitorMediaStreamException.Limit> {
            MonitorMediaStreamPump().transfer(Source(byteArrayOf(1, 2, 3)), sink = Sink(), maxByteCount = 2)
        }
    }
}
