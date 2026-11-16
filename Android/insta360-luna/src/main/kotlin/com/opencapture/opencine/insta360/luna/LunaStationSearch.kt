package com.opencapture.opencine.insta360.luna

import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ConcurrentLinkedQueue
import com.opencapture.opencine.core.ConnectionFailure
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.CancellationException

/**
 * Finds a camera in station role (iOS `LunaStationPath.findCamera`): it has no fixed address
 * (firmware 1.1.15 reports none over Bluetooth), so the phone's network is searched for the Luna
 * control port answering the UCD2 greeting. The control link then checks the camera's serial, and
 * another camera on the same network is skipped.
 */
internal object LunaStationSearch {
    private val MAGIC = "UCD2".toByteArray()

    /**
     * The first of [hosts] (nearest first) answering [port], searched in rounds of 32 until
     * [budgetMs] runs out; hosts in [excluding] are never probed. [open] makes an unconnected
     * socket on the setup's network.
     */
    suspend fun find(
        hosts: List<String>, port: Int, preface: ByteArray, budgetMs: Long,
        open: () -> Socket, isCurrent: () -> Boolean, excluding: Set<String> = emptySet(),
    ): String? {
        val sockets = ConcurrentLinkedQueue<Socket>()
        return find(
            hosts, budgetMs, excluding, isCurrent, probe = socketProbe(port, preface, open, sockets),
            afterBatch = { closeAll(sockets) },
        )
    }

    /**
     * [find] with [probe] answering for each host and the search time on [nowMs]; the pause
     * between rounds is a coroutine delay. [afterBatch] runs once a batch has its answer.
     */
    suspend fun find(
        hosts: List<String>, budgetMs: Long, excluding: Set<String>, isCurrent: () -> Boolean,
        nowMs: () -> Long = ::monotonicMs, probe: suspend (host: String) -> Boolean, afterBatch: () -> Unit = {},
    ): String? {
        val searched = hosts.filter { it !in excluding }
        val deadline = nowMs() + budgetMs
        while (nowMs() < deadline) {
            for (batch in searched.chunked(32)) {
                kotlin.coroutines.coroutineContext.ensureActive()
                if (!isCurrent()) throw CancellationException("camera connection changed")
                batch(batch, probe, afterBatch)?.let { return it }
                if (nowMs() >= deadline) return null
            }
            delay(1_000)
        }
        return null
    }

    /**
     * The camera this connect asked for on a network several cameras may share (Swift
     * `LunaStationPath.findRequestedCamera`): [find] until [connect] takes a host. A host [connect]
     * turns down as another camera (a [LunaStationFailure] whose reason is wrong camera: its
     * serial is not the one Bluetooth read) is left out from then on and the search goes on within
     * the same [budgetMs]. Hosts in [excluding] (other connections of this app hold them) are
     * never probed. Null when the budget ran out first; any other failure of [connect] ends the
     * search.
     */
    suspend fun findRequested(
        hosts: List<String>, port: Int, preface: ByteArray, budgetMs: Long, excluding: Set<String>,
        open: () -> Socket, isCurrent: () -> Boolean, connect: suspend (host: String) -> Unit,
    ): String? {
        val sockets = ConcurrentLinkedQueue<Socket>()
        return findRequested(
            hosts, budgetMs, excluding, isCurrent, probe = socketProbe(port, preface, open, sockets),
            afterBatch = { closeAll(sockets) }, connect = connect,
        )
    }

    /** [findRequested] with [probe] answering for each host and the search time on [nowMs]. */
    suspend fun findRequested(
        hosts: List<String>, budgetMs: Long, excluding: Set<String>, isCurrent: () -> Boolean,
        nowMs: () -> Long = ::monotonicMs, probe: suspend (host: String) -> Boolean, afterBatch: () -> Unit = {},
        connect: suspend (host: String) -> Unit,
    ): String? {
        val deadline = nowMs() + budgetMs
        val skipped = excluding.toMutableSet()
        do {
            val host = find(hosts, deadline - nowMs(), skipped, isCurrent, nowMs, probe, afterBatch) ?: return null
            try {
                connect(host)
                return host
            } catch (failure: LunaStationFailure) {
                if (failure.failure.reason != ConnectionFailure.Reason.WrongCamera) throw failure
                skipped += host
            }
        } while (nowMs() < deadline)
        return null
    }

    private fun monotonicMs(): Long = System.nanoTime() / 1_000_000

    private fun socketProbe(port: Int, preface: ByteArray, open: () -> Socket, sockets: MutableCollection<Socket>): suspend (String) -> Boolean =
        { host -> withContext(Dispatchers.IO) { probe(host, port, preface, open, sockets) } }

    /** Unblocks the probes still waiting. */
    private fun closeAll(sockets: ConcurrentLinkedQueue<Socket>) {
        while (true) {
            val socket = sockets.poll() ?: return
            runCatching { socket.close() }
        }
    }

    private suspend fun batch(hosts: List<String>, probe: suspend (String) -> Boolean, afterBatch: () -> Unit): String? = coroutineScope {
        val found = CompletableDeferred<String?>()
        val probes = hosts.map { host ->
            launch { if (probe(host)) found.complete(host) }
        }
        launch { probes.joinAll(); found.complete(null) }
        val host = found.await()
        afterBatch()
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
