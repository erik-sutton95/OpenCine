package com.opencapture.opencine.relayruntime

import com.opencapture.opencine.relay.RelayControlWireCodec
import com.opencapture.opencine.relay.RelayPeerHello
import com.opencapture.opencine.relay.RelaySocketPolicy
import com.opencapture.opencine.relay.RelayStreamBuffer
import com.opencapture.opencine.relay.RelayStreamFraming
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch

public sealed interface RelayClientEvent<out State, out Metadata, out Control, out Denied> {
    public val source: UUID
    public data class Connected(public val hello: RelayPeerHello, override val source: UUID) : RelayClientEvent<Nothing, Nothing, Nothing, Nothing>
    public data class StateReceived<State>(public val state: State, override val source: UUID) : RelayClientEvent<State, Nothing, Nothing, Nothing>
    public data class FrameReceived<Metadata>(public val metadata: Metadata, public val image: ByteArray, override val source: UUID) : RelayClientEvent<Nothing, Metadata, Nothing, Nothing>
    public data class ControlChanged<Control>(public val control: Control, override val source: UUID) : RelayClientEvent<Nothing, Nothing, Control, Nothing>
    public data class JoinDenied<Denied>(public val denied: Denied, override val source: UUID) : RelayClientEvent<Nothing, Nothing, Nothing, Denied>
    public data class Closed(public val reason: String?, override val source: UUID) : RelayClientEvent<Nothing, Nothing, Nothing, Nothing>
}

/** One bounded stream and its source/control lifetime. Pre-connection commands are refused;
 * only the current introduction is dispatched after a successful connect. */
public class RelaySocketClient<State, Metadata, Command, Control, Denied>(
    private val scope: CoroutineScope,
    private val codec: RelayControlWireCodec<State, Metadata, Command, Control, Denied>,
    private val sockets: RelaySocketFactory = JdkRelaySocketFactory(),
    private val policy: RelaySocketPolicy = RelaySocketPolicy(),
) : RelayViewerConnection<State, Metadata, Command, Control, Denied> {
    private val lock: Any = Any()
    private var source: UUID = UUID.randomUUID()
    private var active: Boolean = false
    private var introduced: Boolean = false
    private var hasControl: Boolean = false
    private var controlRevision: Long = 0
    private var lastControl: Control? = null
    private var socket: RelayDuplex? = null
    private var reader: Job? = null
    private var writer: Job? = null
    private data class Packet(val data: ByteArray, val revision: Long?)
    private var outbound: Channel<Packet> = Channel(policy.maximumControlQueue)
    private val published: MutableSharedFlow<RelayClientEvent<State, Metadata, Control, Denied>> = MutableSharedFlow(extraBufferCapacity = 16)
    override public val events: SharedFlow<RelayClientEvent<State, Metadata, Control, Denied>> = published.asSharedFlow()
    override public val currentSource: UUID get() = synchronized(lock) { source }

    override public fun connect(host: String, port: Int, hello: RelayPeerHello): Unit {
        val window = synchronized(lock) {
            retireLocked()
            active = true
            source
        }
        val reading = scope.launch(start = CoroutineStart.LAZY) {
            var connection: RelayDuplex? = null
            try {
                val connected = sockets.connect(host, port, policy.connectTimeoutMillis)
                connection = connected
                val queue = synchronized(lock) {
                    if (!admits(window)) null else { socket = connected; outbound }
                } ?: return@launch
                // HELLO always precedes controls; it cannot be replaced by an old writer queue.
                connected.write(RelayStreamFraming.encode(0x01, codec.encodeHello(hello)))
                val writing = scope.launch(start = CoroutineStart.LAZY) {
                    try {
                        for (packet in queue) {
                            val allowed = synchronized(lock) {
                                admits(window) && socket === connected &&
                                    (packet.revision == null || (hasControl && packet.revision == controlRevision))
                            }
                            if (allowed) connected.write(packet.data)
                        }
                    } catch (error: Exception) { fail(window, error.message) }
                }
                if (synchronized(lock) { if (admits(window)) { writer = writing; true } else false }) writing.start()
                else writing.cancel()
                val buffer = RelayStreamBuffer(codec.profile)
                while (synchronized(lock) { admits(window) && socket === connected }) {
                    val bytes = connected.receive(policy.receiveChunkBytes) ?: break
                    for (message in buffer.append(bytes)) {
                        if (!synchronized(lock) { admits(window) }) break
                        when (message.kind) {
                            0x01 -> {
                                val introduction = codec.decodeHello(message.payload)
                                if (introduction.version != codec.profile.version) {
                                    fail(window, policy.versionMismatchReason)
                                    return@launch
                                }
                                synchronized(lock) { if (admits(window)) introduced = true }
                                emit(window, RelayClientEvent.Connected(introduction, window))
                            }
                            0x02 -> emit(window, RelayClientEvent.StateReceived(codec.decodeState(message.payload), window))
                            0x03 -> {
                                val frame = codec.decodeFrame(message.payload)
                                emit(window, RelayClientEvent.FrameReceived(frame.metadata, frame.image, window))
                            }
                            0x04 -> {
                                val control = codec.decodeControl(message.payload)
                                synchronized(lock) {
                                    if (admits(window)) {
                                        if (lastControl != control) controlRevision += 1
                                        lastControl = control
                                        hasControl = codec.holderIsRecipient(control)
                                    }
                                }
                                emit(window, RelayClientEvent.ControlChanged(control, window))
                            }
                            0x05 -> {
                                emit(window, RelayClientEvent.JoinDenied(codec.decodeDenied(message.payload), window))
                                fail(window, null, notify = false)
                                return@launch
                            }
                        }
                    }
                }
                fail(window, null)
            } catch (error: Exception) { fail(window, error.message) }
            finally { connection?.close() }
        }
        if (synchronized(lock) { if (admits(window)) { reader = reading; true } else false }) reading.start()
        else reading.cancel()
    }
    override public fun requestControl(): Boolean = offer(0x10, ByteArray(0), command = false)
    override public fun releaseControl(): Boolean = offer(0x11, ByteArray(0), command = false)
    override public fun sendCommand(command: Command): Boolean = offer(0x12, codec.encodeCommand(command), command = true)
    private fun offer(kind: Int, bytes: ByteArray, command: Boolean): Boolean = synchronized(lock) {
        if (!active || !introduced || socket == null || (command && !hasControl)) false
        else outbound.trySend(Packet(RelayStreamFraming.encode(kind, bytes), if (command) controlRevision else null)).isSuccess
    }
    override public suspend fun stop(): Unit { synchronized(lock) { retireLocked() } }
    private fun admits(window: UUID): Boolean = active && source == window
    private suspend fun emit(window: UUID, event: RelayClientEvent<State, Metadata, Control, Denied>): Unit {
        if (synchronized(lock) { admits(window) }) published.emit(event)
    }
    private suspend fun fail(window: UUID, reason: String?, notify: Boolean = true): Unit {
        val retired = synchronized(lock) {
            if (!admits(window)) false else { retireLocked(cancelJobs = false, rotatingSource = false); true }
        }
        if (retired && notify) published.emit(RelayClientEvent.Closed(reason, window))
    }
    private fun retireLocked(cancelJobs: Boolean = true, rotatingSource: Boolean = true): Unit {
        if (rotatingSource) source = UUID.randomUUID()
        active = false
        introduced = false
        hasControl = false
        controlRevision += 1
        lastControl = null
        if (cancelJobs) { reader?.cancel(); writer?.cancel() }
        socket?.close()
        socket = null
        outbound.close()
        outbound = Channel(policy.maximumControlQueue)
    }
}
