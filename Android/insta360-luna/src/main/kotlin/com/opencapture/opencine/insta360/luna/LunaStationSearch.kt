package com.opencapture.opencine.insta360.luna

import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ConcurrentLinkedQueue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.CancellationException

/**
 * Finds a camera in station role (iOS `LunaStationPath.findCamera`): it has no fixed address
 * (firmware 1.1.15 reports none over Bluetooth), so the phone's network is searched for the Luna
 * control port answering the UCD2 greeting. The control link then checks the camera as usual.
 */
internal object LunaStationSearch {
    private val MAGIC = "UCD2".toByteArray()

    /**
     * The first of [hosts] (nearest first) answering [port], searched in rounds of 32 until
     * [budgetMs] runs out. [open] makes an unconnected socket on the setup's network.
     */
    suspend fun find(
        hosts: List<String>, port: Int, preface: ByteArray, budgetMs: Long,
        open: () -> Socket, isCurrent: () -> Boolean,
    ): String? {
        val deadline = System.nanoTime() + budgetMs * 1_000_000
        while (System.nanoTime() < deadline) {
            for (batch in hosts.chunked(32)) {
                kotlin.coroutines.coroutineContext.ensureActive()
                if (!isCurrent()) throw CancellationException("camera connection changed")
                batch(batch, port, preface, open)?.let { return it }
            }
            delay(1_000)
        }
        return null
    }

    private suspend fun batch(hosts: List<String>, port: Int, preface: ByteArray, open: () -> Socket): String? = coroutineScope {
        val found = CompletableDeferred<String?>()
        val sockets = ConcurrentLinkedQueue<Socket>()
        val probes = hosts.map { host ->
            launch(Dispatchers.IO) { if (probe(host, port, preface, open, sockets)) found.complete(host) }
        }
        launch { probes.joinAll(); found.complete(null) }
        val host = found.await()
        // Unblocks the probes still waiting.
        sockets.forEach { runCatching { it.close() } }
        coroutineContext.cancelChildren()
        host
    }

    /**
     * Connects to [host]:[port], sends the preface and waits up to 2.5 s for a frame that starts
     * with the UCD2 magic (the camera answers slowly in Wi-Fi power save).
     */
    fun probe(host: String, port: Int, preface: ByteArray, open: () -> Socket, sockets: MutableCollection<Socket> = ArrayList()): Boolean {
        val socket = runCatching(open).getOrNull() ?: return false
        sockets += socket
        return try {
            socket.soTimeout = 2_500
            socket.connect(InetSocketAddress(host, port), 1_500)
            socket.getOutputStream().apply { write(preface); flush() }
            val reply = ByteArray(MAGIC.size)
            var read = 0
            val input = socket.getInputStream()
            while (read < reply.size) {
                val count = input.read(reply, read, reply.size - read)
                if (count < 0) break
                read += count
            }
            read == reply.size && reply.contentEquals(MAGIC)
        } catch (_: Exception) {
            false
        } finally {
            runCatching { socket.close() }
        }
    }
}
