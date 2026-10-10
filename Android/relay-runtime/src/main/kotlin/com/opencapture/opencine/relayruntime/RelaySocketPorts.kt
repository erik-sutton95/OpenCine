package com.opencapture.opencine.relayruntime

import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Actual byte transport seam, also driven with controlled reads/writes in owner tests. */
public interface RelayDuplex {
    public suspend fun receive(maximumBytes: Int): ByteArray?
    public suspend fun write(bytes: ByteArray): Unit
    public fun close(): Unit
}

public interface RelaySocketListener {
    public val port: Int
    public suspend fun accept(): RelayDuplex
    public fun close(): Unit
}

public interface RelaySocketFactory {
    public fun listen(preferredPort: Int): RelaySocketListener
    public suspend fun connect(host: String, port: Int, timeoutMillis: Int): RelayDuplex
}

/** JDK socket ownership. This leaf owns no hello, authorization, queue or source policy. */
public class JdkRelaySocketFactory(
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val allowsPreferredPortFallback: Boolean = true,
    private val acceptedTcpNoDelay: Boolean = true,
) : RelaySocketFactory {
    override fun listen(preferredPort: Int): RelaySocketListener {
        val server = if (preferredPort > 0) {
            if (allowsPreferredPortFallback) {
                try { ServerSocket(preferredPort) } catch (_: Exception) { ServerSocket(0) }
            } else { ServerSocket(preferredPort) }
        } else { ServerSocket(0) }
        return object : RelaySocketListener {
            override val port: Int = server.localPort
            override suspend fun accept(): RelayDuplex = withContext(dispatcher) {
                val socket = server.accept()
                socket.tcpNoDelay = acceptedTcpNoDelay
                Duplex(socket)
            }
            override fun close(): Unit { runCatching { server.close() } }
        }
    }
    override suspend fun connect(host: String, port: Int, timeoutMillis: Int): RelayDuplex = withContext(dispatcher) {
        val socket = Socket()
        try {
            socket.tcpNoDelay = true
            socket.keepAlive = true
            socket.connect(InetSocketAddress(host, port), timeoutMillis)
            Duplex(socket)
        } catch (error: Exception) { socket.close(); throw error }
    }
    private inner class Duplex(private val socket: Socket) : RelayDuplex {
        override suspend fun receive(maximumBytes: Int): ByteArray? = withContext(dispatcher) {
            val buffer = ByteArray(maximumBytes)
            val count = socket.getInputStream().read(buffer)
            if (count < 0) null else buffer.copyOf(count)
        }
        override suspend fun write(bytes: ByteArray): Unit = withContext(dispatcher) {
            socket.getOutputStream().apply { write(bytes); flush() }
        }
        override fun close(): Unit { runCatching { socket.close() } }
    }
}
