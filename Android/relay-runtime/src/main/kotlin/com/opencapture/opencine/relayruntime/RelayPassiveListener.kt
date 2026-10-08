package com.opencapture.opencine.relayruntime

import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** An instance-owned passive responder. Null retires it; empty bytes close accepted peers only. */
public class RelayPassiveListener(
    private val port: Int,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val listen: (Int) -> RelaySocketListener = JdkRelaySocketFactory(
        allowsPreferredPortFallback = false, acceptedTcpNoDelay = false)::listen,
    private val onBindFailure: () -> Unit = {},
) {
    init { require(port in 0..65535) }
    private class Window(val socket: RelaySocketListener, var bytes: ByteArray) {
        val source: UUID = UUID.randomUUID()
        val peers: MutableSet<RelayDuplex> = mutableSetOf()
        var job: Job? = null
    }
    private val lock = Any()
    private var window: Window? = null

    public fun update(bytes: ByteArray?): Int? {
        if (bytes == null) { stop(); return null }
        return synchronized(lock) {
            window?.let { it.bytes = bytes.copyOf(); return@synchronized it.socket.port }
            val socket = try { listen(port) } catch (_: IOException) { onBindFailure(); return@synchronized null }
            val started = Window(socket, bytes.copyOf())
            window = started
            val job = scope.launch(dispatcher, start = CoroutineStart.LAZY) { accept(started) }
            started.job = job
            job.start()
            socket.port
        }
    }
    public fun stop(): Unit {
        val retired = synchronized(lock) { window.also { window = null } }
        if (retired != null) close(retired)
    }
    private fun current(expected: Window): Boolean = synchronized(lock) { window?.source == expected.source }
    private suspend fun accept(expected: Window): Unit {
        try {
            while (current(expected)) {
                val peer = expected.socket.accept()
                val payload = synchronized(lock) {
                    if (window?.source != expected.source) null
                    else { expected.peers.add(peer); expected.bytes.copyOf() }
                }
                try {
                    if (payload == null) return
                    if (payload.isNotEmpty() && current(expected)) peer.write(payload)
                } finally {
                    peer.close()
                    synchronized(lock) { expected.peers.remove(peer) }
                }
            }
        } catch (_: IOException) {
            // A listener withdrawn by stop has no successor failure to publish.
        } finally {
            synchronized(lock) { if (window?.source == expected.source) window = null }
            close(expected)
        }
    }
    private fun close(expected: Window): Unit {
        expected.socket.close()
        val peers = synchronized(lock) { expected.peers.toList().also { expected.peers.clear() } }
        peers.forEach(RelayDuplex::close)
        expected.job?.cancel()
    }
}
