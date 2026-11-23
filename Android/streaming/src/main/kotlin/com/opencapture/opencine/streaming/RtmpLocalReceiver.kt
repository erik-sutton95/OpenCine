package com.opencapture.opencine.streaming

import java.io.IOException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * A plain RTMP listener on this device, so a camera on the same network (or on this phone's
 * hotspot) can publish its own stream here; twin of Swift `RTMPLocalReceiver`. Each connection runs
 * its own shared receive session ([StreamingNativeApi.receiverCreate]) as a candidate and becomes
 * the publisher only when it publishes under [token]; at most [MAX_CANDIDATES] wait, each for
 * [publishWindowMs]. Events arrive on the connections' reader threads.
 */
class RtmpLocalReceiver(
    private val port: Int,
    private val token: String,
    private val native: StreamingNativeApi,
    private val publishWindowMs: Long = 10_000,
    private val onEvent: (Event) -> Unit,
) {
    sealed interface Event {
        data class Listening(val port: Int) : Event
        data class ListenFailed(val reason: String) : Event
        data class PublisherConnected(val remote: String) : Event
        data class PublisherDisconnected(val remote: String, val reason: String) : Event
        data class Session(val event: RtmpReceiveEvent) : Event
    }

    private inner class Peer(val socket: Socket) {
        val owner: String = native.receiverCreate(token)
        val remote: String = socket.remoteSocketAddress.toString()
    }

    private val lock = Any()
    private var server: ServerSocket? = null
    private var publisher: Peer? = null
    private val candidates = mutableListOf<Peer>()
    @Volatile private var timers: ScheduledExecutorService? = null

    fun start() {
        synchronized(lock) {
            if (server != null) return
            val socket = try {
                ServerSocket().apply {
                    reuseAddress = true
                    bind(InetSocketAddress(port))
                }
            } catch (error: IOException) {
                null
            } ?: return onEvent(Event.ListenFailed("bind failed"))
            server = socket
            timers = Executors.newSingleThreadScheduledExecutor()
            Thread({ acceptLoop(socket) }, "rtmp-receiver-accept").apply { isDaemon = true }.start()
        }
        server?.let { onEvent(Event.Listening(it.localPort)) }
    }

    /** Closes every connection and the listener. */
    fun stop() {
        val closing = synchronized(lock) {
            val all = listOfNotNull(publisher) + candidates
            publisher = null
            candidates.clear()
            server?.close()
            server = null
            timers?.shutdownNow()
            timers = null
            all
        }
        for (peer in closing) close(peer)
    }

    private fun acceptLoop(socket: ServerSocket) {
        while (!socket.isClosed) {
            val next = try {
                socket.accept()
            } catch (_: IOException) {
                return
            }
            runCatching { next.tcpNoDelay = true }
            // Registered, timed and started under the lock, so a concurrent stop() either sees the
            // peer (and closes it) or the peer is never admitted.
            val admitted = try {
                synchronized(lock) {
                    if (candidates.size >= MAX_CANDIDATES || server !== socket) return@synchronized false
                    val peer = Peer(next)
                    candidates += peer
                    timers?.schedule({ expire(peer) }, publishWindowMs, TimeUnit.MILLISECONDS)
                    Thread({ read(peer) }, "rtmp-receiver-peer").apply { isDaemon = true }.start()
                    true
                }
            } catch (_: Exception) {
                false
            }
            if (!admitted) runCatching { next.close() }
        }
    }

    private fun expire(peer: Peer) {
        val waiting = synchronized(lock) { candidates.contains(peer) }
        if (waiting) drop(peer, "did not publish in time")
    }

    private fun read(peer: Peer) {
        val input = try {
            peer.socket.getInputStream()
        } catch (_: IOException) {
            return drop(peer, "connection failed")
        }
        val buffer = ByteArray(256 * 1024)
        while (true) {
            val count = try {
                input.read(buffer)
            } catch (_: IOException) {
                -1
            }
            if (count < 0) return drop(peer, "publisher closed the connection")
            if (!isOpen(peer)) return
            val reply = RtmpReceiveReply.decode(native.receiverFeed(peer.owner, buffer.copyOf(count)))
            if (reply.outbound.isNotEmpty()) {
                try {
                    peer.socket.getOutputStream().write(reply.outbound)
                } catch (_: IOException) {
                    return drop(peer, "write failed")
                }
            }
            for (event in reply.events) {
                if (event == RtmpReceiveEvent.Closed) continue
                if (event == RtmpReceiveEvent.Publish) promote(peer)
                if (synchronized(lock) { publisher === peer }) onEvent(Event.Session(event))
            }
            if (reply.closed) return drop(peer, "session closed")
        }
    }

    private fun isOpen(peer: Peer) = synchronized(lock) { publisher === peer || candidates.contains(peer) }

    /** A candidate published under the key: it becomes the publisher, replacing any earlier one. */
    private fun promote(peer: Peer) {
        val old = synchronized(lock) {
            // Already the publisher, or dropped meanwhile (expired, or the receiver stopped).
            if (publisher === peer || !candidates.remove(peer)) return
            publisher.also { publisher = peer }
        }
        if (old != null) {
            close(old)
            onEvent(Event.PublisherDisconnected(old.remote, "replaced by a new publisher"))
        }
        onEvent(Event.PublisherConnected(peer.remote))
    }

    private fun drop(peer: Peer, reason: String) {
        val wasPublisher = synchronized(lock) {
            candidates.remove(peer)
            (publisher === peer).also { if (it) publisher = null }
        }
        close(peer)
        if (wasPublisher) onEvent(Event.PublisherDisconnected(peer.remote, reason))
    }

    private fun close(peer: Peer) {
        runCatching { peer.socket.close() }
        runCatching { native.receiverClose(peer.owner) }
    }

    companion object {
        const val MAX_CANDIDATES = 4
    }
}
