package com.opencapture.opencine.watchruntime

import com.opencapture.opencine.relay.RelayLatestPreviewPump
import com.opencapture.opencine.relay.RelayPreviewPacing
import com.opencapture.opencine.relay.RelayPreviewPacingPolicy
import com.opencapture.opencine.relay.RelayPreviewProfile
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

public data class WatchPhonePolicy(
    public val pacing: RelayPreviewPacingPolicy,
    public val maximumInFlight: Int = 3,
    public val acknowledgementTimeoutMillis: Long = 2_000,
    public val heartbeatMillis: Long = 2_000,
) {
    init { require(maximumInFlight > 0 && acknowledgementTimeoutMillis > 0 && heartbeatMillis > 0) }
}

public data class WatchCommandAdmission(public val source: UUID, public val peer: String, public val request: Long)

/** Foreground phone relay shared across platform adapters. It owns heartbeat/coalescing,
 * acknowledged latest-preview pacing and exact node/request/source command delivery. */
public class WatchPhoneOwner<State, Frame, Command, Result, Timecode, Preview : Any>(
    private val scope: CoroutineScope,
    private val codec: WatchRelayCodec<State, Frame, Command, Result, Timecode>,
    private val scheduler: WatchRuntimeScheduler,
    private val messages: WatchMessagePort,
    private val policy: WatchPhonePolicy,
    private val encode: suspend (Preview, RelayPreviewProfile) -> Frame?,
    private val discard: (Preview) -> Unit = {},
) {
    private var active: Boolean = false
    private var closed: Boolean = false
    private var window: UUID = UUID.randomUUID()
    private var nodes: Set<String> = emptySet()
    private var latestState: State? = null
    private var lastSentState: State? = null
    private var stateSequence: Long = 0
    private var heartbeat: WatchScheduled? = null
    private val pacing: RelayPreviewPacing = RelayPreviewPacing(policy.pacing)
    private data class Ack(val source: UUID, val sentAt: Long, val nodes: MutableSet<String>, var timeout: WatchScheduled?, var failed: Boolean = false)
    private val acknowledgements: MutableMap<Long, Ack> = mutableMapOf()
    private val pump: RelayLatestPreviewPump<Preview> = RelayLatestPreviewPump(
        maximumInFlight = policy.maximumInFlight, dispatch = ::dispatchPreview, onDiscard = discard)
    public var onCommand: (suspend (WatchRelayAction, WatchCommandAdmission) -> Result)? = null
    public var onSourceRetired: ((UUID) -> Unit)? = null
    public val source: UUID @Synchronized get() = window
    public val isActive: Boolean @Synchronized get() = active
    public val currentState: State? @Synchronized get() = latestState
    public val canPreview: Boolean @Synchronized get() = active && nodes.isNotEmpty() && latestState?.let { codec.facts(it).feedLive } == true
    public fun currentProfile(): RelayPreviewProfile = pacing.currentProfile

    @Synchronized public fun activate(): Boolean {
        if (active || closed) return false
        active = true
        retireSource(resetPacing = true)
        return true
    }
    @Synchronized public fun deactivate(): Boolean {
        if (!active) return false
        active = false
        nodes = emptySet()
        retireSource(resetPacing = true)
        return true
    }
    @Synchronized public fun close(): Unit { deactivate(); closed = true; onCommand = null }
    @Synchronized public fun retireSource(resetPacing: Boolean = false, clearState: Boolean = false): Unit {
        window = UUID.randomUUID()
        stateSequence += 1
        lastSentState = null
        if (clearState) latestState = null
        heartbeat?.cancel()
        heartbeat = null
        acknowledgements.values.forEach { it.timeout?.cancel() }
        acknowledgements.clear()
        if (resetPacing) pacing.reset()
        pump.invalidate()
        onSourceRetired?.invoke(window)
    }
    @Synchronized public fun acceptNodes(reachable: Set<String>, source: UUID): Unit {
        if (!active || window != source) return
        if (nodes != reachable) { nodes = reachable.toSet(); retireSource(resetPacing = true) }
        lastSentState = null
        latestState?.let { publishState(it, force = true) }
    }
    @Synchronized public fun publishState(state: State, force: Boolean = false): Unit {
        val previous = latestState?.let(codec::facts)
        latestState = state
        val facts = codec.facts(state)
        if (previous != null && previous != facts) retireSource()
        if (!facts.feedLive) {
            acknowledgements.values.forEach { it.timeout?.cancel() }
            acknowledgements.clear()
            pump.invalidate()
        }
        sendState(state, force || facts.connection == WatchRelayConnection.DISCONNECTED)
        heartbeat?.cancel()
        heartbeat = null
        if (active && facts.connection != WatchRelayConnection.DISCONNECTED) scheduleHeartbeat(window)
    }
    /** Presented frame metadata is typed payload content, independent of state heartbeat cadence. */
    @Synchronized public fun updateFrameState(state: State): Unit { latestState = state }
    @Synchronized public fun ingestPreview(preview: Preview, source: UUID = window): Unit {
        if (window == source && canPreview) pump.offer(preview) else discard(preview)
    }
    @Synchronized public fun admits(admission: WatchCommandAdmission): Boolean =
        active && window == admission.source && admission.peer in nodes

    @Synchronized public fun receive(node: String, path: String, data: ByteArray, source: UUID): Unit {
        if (!active || source != window || node !in nodes) return
        val token = codec.paths.requestID(path, codec.paths.frameAck)
        if (token != null) { completeDestination(node, token, failed = false); return }
        val request = codec.paths.requestID(path, codec.paths.command) ?: return
        val message = codec.decode(data)
        if (message !is WatchRelayMessage.Command) return
        val admission = WatchCommandAdmission(window, node, request)
        val command = codec.action(message.value)
        val handler = onCommand
        scope.launch {
            if (!admits(admission)) return@launch
            val result = try {
                handler?.invoke(command, admission) ?: codec.result(false, false, "unavailable")
            } catch (_: Exception) { codec.result(false, false, "unavailable") }
            if (admits(admission)) messages.send(node, codec.paths.path(codec.paths.result, request), codec.encodeResult(result), null)
        }
    }

    private fun dispatchPreview(dispatch: RelayLatestPreviewPump.Dispatch<Preview>): Unit {
        val source = this.source
        val profile = pacing.currentProfile
        scope.launch {
            val frame = try {
                if (isCurrentPreview(source, dispatch.token)) encode(dispatch.value, profile) else null
            } catch (_: Exception) {
                null
            } finally { discard(dispatch.value) }
            synchronized(this@WatchPhoneOwner) {
                if (frame == null || !isCurrentPreview(source, dispatch.token)) { pump.complete(dispatch.token); return@launch }
                val destinations = nodes.toSet()
                val data = try { codec.encodeFrame(frame) } catch (_: Exception) {
                    pump.complete(dispatch.token)
                    return@launch
                }
                val ack = Ack(source, scheduler.nowMillis(), destinations.toMutableSet(), timeout = null)
                acknowledgements[dispatch.token] = ack
                val timeout = scheduler.schedule(policy.acknowledgementTimeoutMillis) { expirePreview(source, dispatch.token) }
                if (acknowledgements[dispatch.token] === ack) ack.timeout = timeout else timeout.cancel()
                destinations.forEach { node ->
                    if (isCurrentPreview(source, dispatch.token)) {
                        messages.send(node, codec.paths.path(codec.paths.frame, dispatch.token), data) {
                            completeDestination(node, dispatch.token, failed = true)
                        }
                    }
                }
            }
        }
    }
    @Synchronized private fun isCurrentPreview(source: UUID, token: Long): Boolean =
        window == source && canPreview && pump.isActive(token)
    @Synchronized private fun completeDestination(node: String, token: Long, failed: Boolean): Unit {
        val ack = acknowledgements[token] ?: return
        if (!isCurrentPreview(ack.source, token) || !ack.nodes.remove(node)) return
        ack.failed = ack.failed || failed
        if (ack.nodes.isNotEmpty()) return
        acknowledgements.remove(token)
        ack.timeout?.cancel()
        if (ack.failed) pacing.timedOut() else pacing.acknowledgeInSampleUnits(
            (scheduler.nowMillis() - ack.sentAt).coerceAtLeast(1).toDouble() * (policy.pacing.sampleUnitsPerSecond / 1_000.0))
        pump.complete(token)
    }
    @Synchronized private fun expirePreview(source: UUID, token: Long): Unit {
        if (!isCurrentPreview(source, token) || acknowledgements.remove(token) == null) return
        pacing.timedOut()
        pump.complete(token)
    }
    private fun sendState(state: State, force: Boolean): Unit {
        if (!active || nodes.isEmpty() || (!force && lastSentState?.let { codec.stateMatches(state, it) } == true)) return
        val data = codec.encodeState(state)
        lastSentState = state
        stateSequence += 1
        val sequence = stateSequence
        val source = window
        nodes.toSet().forEach { node ->
            if (active && source == window && node in nodes) messages.send(node, codec.paths.state, data) {
                synchronized(this) { if (source == window && stateSequence == sequence) lastSentState = null }
            }
        }
    }
    private fun scheduleHeartbeat(source: UUID): Unit {
        heartbeat = scheduler.schedule(policy.heartbeatMillis) {
            synchronized(this) {
                if (!active || window != source) return@synchronized
                val state = latestState ?: return@synchronized
                if (codec.facts(state).connection == WatchRelayConnection.DISCONNECTED) return@synchronized
                sendState(state, force = true)
                scheduleHeartbeat(source)
            }
        }
    }
}
