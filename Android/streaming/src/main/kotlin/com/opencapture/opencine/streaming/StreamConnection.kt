package com.opencapture.opencine.streaming

import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/** What a stream connection reports, in order, from its own threads. */
sealed interface StreamConnectionEvent {
    data object Opened : StreamConnectionEvent

    class Received(val bytes: ByteArray) : StreamConnectionEvent {
        override fun toString(): String = "Received(${bytes.size} bytes)"
    }

    /** One earlier `write` reached the socket, all [count] bytes of it. */
    data class Wrote(val count: Int) : StreamConnectionEvent

    /** The connection failed or the peer closed it. Reported at most once, never after `close`. */
    data object Lost : StreamConnectionEvent
}

/** One connection to an ingest server. */
interface StreamConnection {
    fun open(onEvent: (StreamConnectionEvent) -> Unit)

    /** Queues [bytes]; a `Wrote` follows once they are written. Ignored once lost or closed. */
    fun write(bytes: ByteArray)

    fun close()
}

/**
 * A TCP connection with TLS for `rtmps://` (system trust store, SNI and host name verification,
 * no pinning) or plain for an `rtmp://` server the engine accepted. Connecting and reading run on
 * one thread, writing on another; events arrive from either, in order per kind.
 */
class SocketStreamConnection(
    private val host: String,
    private val port: Int,
    private val tls: Boolean,
    private val connectTimeoutMs: Int = 10_000,
) : StreamConnection {
    private val writer = Executors.newSingleThreadExecutor { Thread(it, "opc.stream.write").apply { isDaemon = true } }
    private val ended = AtomicBoolean(false)
    @Volatile private var socket: Socket? = null
    @Volatile private var onEvent: (StreamConnectionEvent) -> Unit = {}

    override fun open(onEvent: (StreamConnectionEvent) -> Unit) {
        this.onEvent = onEvent
        Thread({ connectAndRead() }, "opc.stream.read").apply { isDaemon = true }.start()
    }

    override fun write(bytes: ByteArray) {
        if (ended.get()) return
        runCatching {
            writer.execute {
                val output = socket?.takeUnless { ended.get() }?.getOutputStream() ?: return@execute
                try {
                    output.write(bytes)
                    output.flush()
                    if (!ended.get()) onEvent(StreamConnectionEvent.Wrote(bytes.size))
                } catch (_: IOException) {
                    lose()
                }
            }
        }
    }

    override fun close() {
        if (!ended.compareAndSet(false, true)) {
            writer.shutdownNow()
            return
        }
        runCatching { socket?.close() }
        writer.shutdownNow()
    }

    private fun connectAndRead() {
        val opened = try {
            connect()
        } catch (_: IOException) {
            lose()
            return
        }
        socket = opened
        if (ended.get()) {
            runCatching { opened.close() }
            return
        }
        onEvent(StreamConnectionEvent.Opened)
        val buffer = ByteArray(64 * 1024)
        try {
            val input = opened.getInputStream()
            while (!ended.get()) {
                val count = input.read(buffer)
                if (count < 0) break
                if (count > 0 && !ended.get()) onEvent(StreamConnectionEvent.Received(buffer.copyOf(count)))
            }
        } catch (_: IOException) {
            // Lost below.
        }
        lose()
    }

    private fun connect(): Socket {
        val plain = Socket()
        try {
            plain.tcpNoDelay = true
            plain.connect(InetSocketAddress(host, port), connectTimeoutMs)
            if (!tls) return plain
            val secure = (SSLSocketFactory.getDefault() as SSLSocketFactory)
                .createSocket(plain, host, port, true) as SSLSocket
            secure.sslParameters = secure.sslParameters.apply {
                if (host.any { it.isLetter() } && !host.contains(':')) serverNames = listOf(SNIHostName(host))
            }
            secure.startHandshake()
            if (!HttpsURLConnection.getDefaultHostnameVerifier().verify(host, secure.session)) {
                secure.close()
                throw IOException("server certificate does not name the host")
            }
            return secure
        } catch (error: IOException) {
            runCatching { plain.close() }
            throw error
        }
    }

    private fun lose() {
        if (!ended.compareAndSet(false, true)) return
        runCatching { socket?.close() }
        onEvent(StreamConnectionEvent.Lost)
        writer.shutdown()
    }
}
