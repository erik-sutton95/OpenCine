package com.opencapture.opencine.watchruntime

import com.opencapture.opencine.relay.RelayWatchFrameSequence
import com.opencapture.opencine.relay.RelayWatchFreshness
import com.opencapture.opencine.relay.RelayWatchPendingCommand
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

public data class WatchReceiverSnapshot<State, Timecode, Image>(
    public val presentationRevision: Long = 0,
    public val state: State? = null,
    public val image: Image? = null,
    public val timecode: Timecode? = null,
    public val phoneReachable: Boolean = false,
    public val isSendingCommand: Boolean = false,
    public val commandMessage: String? = null,
)

/** Foreground Watch receiver: exact peer/request/source admission, authoritative state expiry,
 * ordered frame receipt/ACK and command retirement. Platform listeners and image decode are ports. */
public class WatchReceiverOwner<State, Frame, Command, Result, Timecode, Image>(
    private val codec: WatchRelayCodec<State, Frame, Command, Result, Timecode>,
    private val scheduler: WatchRuntimeScheduler,
    private val messages: WatchMessagePort,
    private val decodeImage: (ByteArray) -> Image?,
    private val policy: WatchReceiverPolicy,
) {
    private var active: Boolean = false
    private var closed: Boolean = false
    private var window: UUID = UUID.randomUUID()
    private var nodes: Set<String> = emptySet()
    private var preferredNode: String? = null
    private var commandSequence: Long = 0
    private var pending: RelayWatchPendingCommand? = null
    private var stateExpiry: WatchScheduled? = null
    private var commandExpiry: WatchScheduled? = null
    private val freshness: RelayWatchFreshness = RelayWatchFreshness(policy.stateFreshnessMillis / 1_000.0)
    private val frames: RelayWatchFrameSequence = RelayWatchFrameSequence()
    private val published: MutableStateFlow<WatchReceiverSnapshot<State, Timecode, Image>> = MutableStateFlow(WatchReceiverSnapshot())
    public val snapshot: StateFlow<WatchReceiverSnapshot<State, Timecode, Image>> = published.asStateFlow()
    public var onSourceRetired: ((UUID) -> Unit)? = null
    public val source: UUID @Synchronized get() = window
    public val isActive: Boolean @Synchronized get() = active

    @Synchronized public fun start(): Boolean {
        if (active || closed) return false
        active = true
        nodes = emptySet()
        preferredNode = null
        retire(clearState = true)
        published.value = published.value.copy(phoneReachable = false)
        return true
    }
    @Synchronized public fun stop(): Unit {
        if (!active) return
        active = false
        nodes = emptySet()
        preferredNode = null
        retire(clearState = true)
        published.value = published.value.copy(phoneReachable = false)
    }
    @Synchronized public fun close(): Unit { stop(); closed = true }

    @Synchronized public fun acceptNodes(reachable: Set<String>, source: UUID): Unit {
        if (!active || window != source) return
        val previousNode = preferredNode
        val previousReachable = nodes.isNotEmpty()
        nodes = reachable.toSet()
        if (preferredNode !in nodes) preferredNode = nodes.minOrNull()
        if (previousNode != preferredNode || previousReachable != nodes.isNotEmpty()) retire(clearState = true)
        published.value = published.value.copy(phoneReachable = nodes.isNotEmpty())
    }

    @Synchronized public fun receive(node: String, path: String, data: ByteArray, source: UUID): Unit {
        if (!active || source != window) return
        val frameRequest = codec.paths.requestID(path, codec.paths.frame)
        if (frameRequest != null) {
            if (node != preferredNode || !freshness.isFresh(scheduler.nowMillis() / 1_000.0)) return
            val state = published.value.state ?: return
            val facts = codec.facts(state)
            if (facts.connection != WatchRelayConnection.CONNECTED || !facts.feedLive) return
            val message = codec.decode(data)
            if (message !is WatchRelayMessage.Frame) return
            val frame = message.value
            messages.send(node, codec.paths.path(codec.paths.frameAck, frameRequest), ByteArray(0), null)
            if (!frames.accept(frameRequest)) return
            val image = decodeImage(codec.image(frame)) ?: return
            if (!active || window != source || node != preferredNode) return
            published.value = published.value.copy(image = image, timecode = codec.timecode(frame))
            return
        }
        if (path == codec.paths.state) {
            if (node !in nodes) return
            val message = codec.decode(data)
            if (message !is WatchRelayMessage.State) return
            val next = message.value
            val before = published.value.state?.let(codec::facts)
            if (preferredNode != node) { preferredNode = node; retire(clearState = true) }
            if (before != codec.facts(next)) retire(clearState = false)
            published.value = published.value.copy(state = next)
            freshness.accept(scheduler.nowMillis() / 1_000.0)
            stateExpiry?.cancel()
            val expected = window
            stateExpiry = scheduler.schedule(policy.stateFreshnessMillis) { expireState(expected) }
            return
        }
        val request = codec.paths.requestID(path, codec.paths.result) ?: return
        val command = pending ?: return
        if (!command.matches(node, request, window)) return
        val message = codec.decode(data)
        if (message !is WatchRelayMessage.Result) return
        commandExpiry?.cancel()
        commandExpiry = null
        pending = null
        val result = message.value
        published.value = published.value.copy(isSendingCommand = false, commandMessage = codec.error(result),
            state = published.value.state?.let { codec.replacing(it, result) })
    }

    @Synchronized public fun sendToggleRecord(): Boolean {
        val state = published.value.state ?: return false
        val node = preferredNode ?: return false
        if (!active || nodes.isEmpty() || !freshness.isFresh(scheduler.nowMillis() / 1_000.0) || pending != null ||
            codec.facts(state).connection != WatchRelayConnection.CONNECTED) return false
        val data = codec.encodeCommand(WatchRelayAction.TOGGLE_RECORD)
        commandSequence += 1
        val command = RelayWatchPendingCommand(node, commandSequence, window)
        pending = command
        published.value = published.value.copy(isSendingCommand = true, commandMessage = null)
        commandExpiry = scheduler.schedule(policy.commandTimeoutMillis) { reject(command, policy.timeoutError) }
        if (pending == command) messages.send(node, codec.paths.path(codec.paths.command, command.request), data) {
            reject(command, policy.unavailableError)
        }
        return true
    }
    @Synchronized private fun reject(command: RelayWatchPendingCommand, reason: String): Unit {
        if (!active || pending != command || window != command.source) return
        pending = null
        commandExpiry?.cancel()
        commandExpiry = null
        published.value = published.value.copy(isSendingCommand = false, commandMessage = reason)
    }
    @Synchronized private fun expireState(expected: UUID): Unit {
        if (!active || window != expected) return
        val remaining = freshness.remainingSeconds(scheduler.nowMillis() / 1_000.0)?.let { kotlin.math.ceil(it * 1_000).toLong() } ?: return
        if (remaining > 0) {
            stateExpiry = scheduler.schedule(remaining) { expireState(expected) }
        } else { retire(clearState = true) }
    }
    private fun retire(clearState: Boolean): Unit {
        window = UUID.randomUUID()
        freshness.clear()
        frames.clear()
        pending = null
        commandExpiry?.cancel()
        commandExpiry = null
        stateExpiry?.cancel()
        stateExpiry = null
        published.value = published.value.copy(presentationRevision = published.value.presentationRevision + 1,
            state = if (clearState) null else published.value.state, image = null, timecode = null,
            isSendingCommand = false, commandMessage = null)
        onSourceRetired?.invoke(window)
    }
}
