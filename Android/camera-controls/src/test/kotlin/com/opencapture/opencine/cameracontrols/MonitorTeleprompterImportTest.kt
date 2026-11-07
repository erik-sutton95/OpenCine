package com.opencapture.opencine.cameracontrols

import com.opencapture.monitorui.TeleprompterScriptImport
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CountDownLatch
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class MonitorTeleprompterImportTest {
    @Test fun unknownLengthStreamsStopAtTheLimitWithoutWaitingForEOF(): Unit = runBlocking {
        val exact = ScriptConnection(SOURCE, ScriptInput(TeleprompterScriptImport.MAXIMUM_BYTES))
        val script = MonitorTeleprompterImport.remote(SOURCE) { exact }
        assertEquals(TeleprompterScriptImport.MAXIMUM_BYTES, script.text.toByteArray().size)

        val oversized = ScriptConnection(SOURCE,
            ScriptInput(TeleprompterScriptImport.MAXIMUM_BYTES + 1, waitAtEOF = true))
        assertFailsWith<IllegalArgumentException> {
            MonitorTeleprompterImport.remote(SOURCE) { oversized }
        }
        assertTrue(oversized.disconnected.isCompleted)
        assertTrue(oversized.input.closed)
    }

    @Test fun cancellingABlockedNativeReadDisconnectsTheRequest(): Unit = runBlocking {
        val connection = ScriptConnection(SOURCE, ScriptInput(0, waitAtEOF = true))
        val pending = async { MonitorTeleprompterImport.remote(SOURCE) { connection } }
        connection.input.readStarted.await()
        pending.cancel()
        pending.join()
        assertTrue(pending.isCancelled)
        assertTrue(connection.disconnected.isCompleted)
        assertTrue(connection.input.closed)
    }

    @Test fun unsafeRedirectsNeverOpenTheirDestination(): Unit = runBlocking {
        for (destination in listOf("http://forbidden.invalid/script.txt",
            "https://reader:placeholder@forbidden.invalid/script.txt")) {
            val opened = mutableListOf<String>()
            val source = ScriptConnection(SOURCE, location = destination)
            assertFailsWith<IllegalArgumentException> {
                MonitorTeleprompterImport.remote(SOURCE) { address ->
                    opened += address
                    check(address == SOURCE) { "Forbidden destination opened" }
                    source
                }
            }
            assertEquals(listOf(SOURCE), opened)
            assertTrue(source.disconnected.isCompleted)
        }
    }

    @Test fun acceptedRedirectRetainsTheOriginalRefreshURL(): Unit = runBlocking {
        val target = "https://scripts.invalid/updated.md"
        val source = ScriptConnection(SOURCE, location = target)
        val destination = ScriptConnection(target, ScriptInput("# Updated\n\n- First cue".toByteArray()))
        val script = MonitorTeleprompterImport.remote(SOURCE) { address ->
            when (address) {
                SOURCE -> source
                target -> destination
                else -> error("Unexpected destination")
            }
        }
        assertEquals("Updated\n\n• First cue", script.text)
        assertEquals(SOURCE, script.sourceUrl)
        assertTrue(source.disconnected.isCompleted && destination.disconnected.isCompleted)
    }

    private companion object {
        const val SOURCE = "https://scripts.invalid/original.txt"
    }
}

// SIMULATED native connection: disconnect releases a pending stream without clocks or sockets.
private class ScriptConnection(address: String, val input: ScriptInput = ScriptInput(0),
    private val location: String? = null) : HttpURLConnection(URL(address)) {
    val disconnected = CompletableDeferred<Unit>()
    override fun connect() = Unit
    override fun usingProxy(): Boolean = false
    override fun getResponseCode(): Int = if (location == null) 200 else 302
    override fun getContentLengthLong(): Long = -1
    override fun getContentType(): String = "text/markdown"
    override fun getHeaderField(name: String?): String? = if (name == "Location") location else null
    override fun getInputStream(): InputStream = input
    override fun disconnect() {
        input.release()
        disconnected.complete(Unit)
    }
}

private class ScriptInput(private val bytes: ByteArray, private val waitAtEOF: Boolean = false) : InputStream() {
    constructor(count: Int, waitAtEOF: Boolean = false) : this(ByteArray(count) { 97 }, waitAtEOF)
    val readStarted = CompletableDeferred<Unit>()
    private val released = CountDownLatch(1)
    private var offset = 0
    @Volatile var closed = false
        private set
    override fun read(): Int {
        val buffer = ByteArray(1)
        return if (read(buffer, 0, 1) < 0) -1 else buffer[0].toInt() and 255
    }
    override fun read(buffer: ByteArray, start: Int, length: Int): Int {
        readStarted.complete(Unit)
        if (offset < bytes.size) {
            val count = minOf(length, bytes.size - offset)
            bytes.copyInto(buffer, start, offset, offset + count)
            offset += count
            return count
        }
        if (!waitAtEOF) return -1
        released.await()
        throw IOException("SIMULATED request disconnected")
    }
    override fun close() { closed = true; release() }
    fun release() { released.countDown() }
}
