package com.opencapture.opencine.insta360.luna

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/** Request correlation is independent of BLE fragmentation and TCP read boundaries. */
internal class LunaChannel(
    private val send: suspend (ByteArray) -> Unit,
    private val video: (ByteArray, Long) -> Unit = { _, _ -> },
    private val notify: (LunaWire.Message) -> Unit = {},
    private val track: (LunaTrackFrame) -> Unit = {},
    private val imu: (List<LunaImuSample>) -> Unit = {},
) {
    private val parser = LunaWire.Parser()
    private val sequence = AtomicInteger()
    private val identifier = AtomicInteger()
    private val sendMutex = Mutex()
    private val pending = ConcurrentHashMap<Int, Pair<CompletableDeferred<LunaWire.Message>, Boolean>>()
    val greeting = CompletableDeferred<Unit>()
    val failure = CompletableDeferred<Throwable>()
    val approvals = Channel<LunaWire.Message>(16)
    @Volatile var key: ByteArray? = null
    fun receive(data: ByteArray) {
        try {
            for (frame in parser.feed(data)) {
                when (frame.type) {
                    5 -> greeting.complete(Unit)
                    1 -> {
                        val bytes = frame.payload
                        require(bytes.size >= 9)
                        when (bytes[0].toInt() and 255) {
                            0x20 -> {
                                val tick = java.nio.ByteBuffer.wrap(bytes, 1, 8).order(java.nio.ByteOrder.LITTLE_ENDIAN).long
                                video(bytes.copyOfRange(9, bytes.size), tick * 1000)
                            }
                            0x30 -> LunaImu.decode(bytes, 9).takeIf { it.isNotEmpty() }?.let(imu)
                            // A malformed Deep Track frame is dropped, not a link failure.
                            0x85 -> runCatching { LunaTrackFrame.parse(bytes.copyOfRange(9, bytes.size)) }.getOrNull()?.let(track)
                        }
                    }
                    4 -> {
                        val message = checkNotNull(frame.message(key))
                        val waiter = pending[message.id]
                        if (waiter != null && message.code in listOf(200, 500)) {
                            require(message.encrypted == waiter.second) { "Response encryption mismatch" }
                            waiter.first.complete(message)
                        } else if (message.code in listOf(8209, 8228)) {
                            check(approvals.trySend(message).isSuccess) { "Approval queue overflow" }
                        } else if (message.code >= 8192) {
                            // A notification the backend cannot decode is dropped, not a link failure.
                            runCatching { notify(message) }
                        }
                    }
                }
            }
        } catch (error: Exception) { fail(error) }
    }
    fun fail(error: Throwable) {
        failure.complete(error)
        greeting.completeExceptionally(error)
        pending.values.forEach { it.first.completeExceptionally(error) }
    }
    suspend fun raw(data: ByteArray) = sendMutex.withLock { send(data) }
    suspend fun heartbeat() = raw(LunaWire.encode(sequence.incrementAndGet() and 255, ByteArray(0), type = 5))
    suspend fun request(code: Int, body: ByteArray = ByteArray(0), encrypted: Boolean = false): ByteArray {
        if (failure.isCompleted) throw failure.await()
        val id = identifier.incrementAndGet()
        val future = CompletableDeferred<LunaWire.Message>()
        pending[id] = future to encrypted
        try {
            val payload = LunaWire.request(code, id, body)
            val encryptionKey = if (encrypted) checkNotNull(key) else null
            raw(LunaWire.encode(sequence.incrementAndGet() and 255, payload, encryptionKey))
            val reply = withTimeout(10_000) { future.await() }
            if (reply.code != 200) throw LunaRefused(code)
            return reply.body
        } finally { pending.remove(id); future.cancel() }
    }
    fun close() { key?.fill(0); key = null; approvals.close(); pending.values.forEach { it.first.cancel() }; pending.clear() }
}
