package com.opencapture.opencine.relayruntime

import com.opencapture.opencine.relay.RelayControlWireCodec
import com.opencapture.opencine.relay.RelayPeerHello
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** Actual socket owner conforms; manual ports vary scheduling, never the deployed payload codec. */
public interface RelayViewerConnection<State, Metadata, Command, Control, Denied> {
    public val currentSource: UUID
    public val events: Flow<RelayClientEvent<State, Metadata, Control, Denied>>
    public fun connect(host: String, port: Int, hello: RelayPeerHello): Unit
    public fun requestControl(): Boolean
    public fun releaseControl(): Boolean
    public fun sendCommand(command: Command): Boolean
    public suspend fun stop(): Unit
}

/** App-owned secure/install namespace. Shared lifetime never chooses a store or credential key. */
public interface RelayViewerCredentials {
    public fun passcode(key: String): String?
    public fun rememberPasscode(key: String, code: String): Unit
    public val jpegOnly: Boolean
    public fun latchJpegOnly(): Unit
}

public data class RelayViewerRefusal(public val reason: String, public val passcodeRequired: Boolean)
public data class RelayViewerFocusCoordinates(public val width: Int, public val height: Int)
public class RelayViewerCommandAdmission internal constructor(
    public val source: UUID, public val revision: Long, internal val owner: UUID,
)
public interface RelayViewerFacts<State, Metadata, Control, Denied> {
    public fun allowsControlRequests(state: State): Boolean?
    public fun holderName(control: Control): String?
    public fun refusal(denied: Denied): RelayViewerRefusal
    public fun focusCoordinates(metadata: Metadata): RelayViewerFocusCoordinates?
}

public data class RelayViewerConfiguration(
    public val host: String,
    public val port: Int,
    public val deviceName: String,
    public val credentialKey: String,
    public val watcherID: String? = null,
)
public data class RelayViewerPolicy(
    public val hevcDecodeDeadlineMillis: Long = 6_000L,
    public val stallDeadlineMillis: Long = 8_000L,
    public val stallPollMillis: Long = 3_000L,
    public val rejoinIntervalMillis: Long = 3_000L,
    public val hevcCodec: Int = 1,
    public val legacyAllowsControlRequests: Boolean = true,
    public val droppedReason: String = "The broadcast dropped.",
    public val unreachableReason: String = "Couldn't reach the broadcast.",
    public val stalledReason: String = "The stream stalled. Reconnecting.",
) {
    init { require(hevcDecodeDeadlineMillis > 0 && stallDeadlineMillis > 0 && stallPollMillis > 0 && rejoinIntervalMillis > 0) }
}
public enum class RelayViewerPhase { CONNECTING, WATCHING, DENIED, FAILED }
public data class RelayViewerStatus<State>(
    public val phase: RelayViewerPhase = RelayViewerPhase.CONNECTING,
    public val hostName: String? = null,
    public val cameraName: String? = null,
    public val holdsControl: Boolean = false,
    public val controlHolderName: String? = null,
    public val allowsControlRequests: Boolean = true,
    public val needsPasscode: Boolean = false,
    public val passcodeWasWrong: Boolean = false,
    public val failureReason: String? = null,
    public val state: State? = null,
    public val endedByBroadcaster: Boolean = false,
)

/**
 * Complete viewer joins, credentials, control, native evidence, receipt stall and rejoin lifetime.
 * Every callback/timer is owned by one concrete connection and picture source. A close cannot
 * borrow another peer's authority, dispatch a camera command or demote a successor decoder.
 */
public class RelayViewerOwner<State, Metadata, Command, Control, Denied, Frame>(
    scope: CoroutineScope,
    private val codec: RelayControlWireCodec<State, Metadata, Command, Control, Denied>,
    private val configuration: RelayViewerConfiguration,
    private val facts: RelayViewerFacts<State, Metadata, Control, Denied>,
    private val picture: RelayDecodedPictureOwner<Metadata, Frame>,
    private val credentials: RelayViewerCredentials,
    private val policy: RelayViewerPolicy = RelayViewerPolicy(),
    dispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val onSourceBegan: (UUID) -> Unit = {},
    private val onConnected: (UUID, RelayPeerHello) -> Unit = { _, _ -> },
    private val onState: (UUID, State) -> Unit = { _, _ -> },
    private val onJpegOnlyLatched: () -> Unit = {},
    private val onPasscodeRemembered: (String) -> Unit = {},
    private val log: (String) -> Unit = {},
    makeConnection: ((CoroutineScope) -> RelayViewerConnection<State, Metadata, Command, Control, Denied>)? = null,
) {
    private inner class Window(val id: UUID, val client: RelayViewerConnection<State, Metadata, Command, Control, Denied>, val passcode: String?) {
        var events: Job? = null
        var stall: Job? = null
        var hevc: Job? = null
        var rejoin: Job? = null
        var hevcArmed: Boolean = false
        var lastFrameAtMillis: Long = nowMillis()
    }
    private val scope: CoroutineScope = CoroutineScope(scope.coroutineContext + dispatcher)
    private val create: (CoroutineScope) -> RelayViewerConnection<State, Metadata, Command, Control, Denied> =
        makeConnection ?: { RelaySocketClient(it, codec) }
    private val lock: Any = Any()
    private val identity: UUID = UUID.randomUUID()
    private var closed: Boolean = false
    private var mutation: UUID = UUID.randomUUID()
    private var current: Window? = null
    private var passcode: String? = null
    private var focus: RelayViewerFocusCoordinates? = null
    private var controlRevision: Long = 0
    private var lastControl: Control? = null
    private val mutableStatus: MutableStateFlow<RelayViewerStatus<State>> = MutableStateFlow(RelayViewerStatus(allowsControlRequests = policy.legacyAllowsControlRequests))
    public val status: StateFlow<RelayViewerStatus<State>> = mutableStatus.asStateFlow()
    public val sourceToken: UUID? get() = synchronized(lock) { current?.id }
    public val focusCoordinates: RelayViewerFocusCoordinates? get() = synchronized(lock) { focus }

    init {
        picture.onExhausted = { source ->
            val window = synchronized(lock) { current?.takeIf { !closed && it.id == source } }
            if (window != null) latchJpeg(window, "decoders exhausted; rejoining for JPEG frames")
        }
    }
    private fun admits(window: Window): Boolean = synchronized(lock) { !closed && current === window }
    private fun publish(window: Window, update: (RelayViewerStatus<State>) -> RelayViewerStatus<State>): Boolean = synchronized(lock) {
        if (closed || current !== window) false else { mutableStatus.value = update(mutableStatus.value); true }
    }

    public fun start(passcode: String? = null): Unit {
        val code = passcode ?: credentials.passcode(configuration.credentialKey)
        synchronized(lock) { if (closed) return; this.passcode = code }
        join()
    }
    private fun join(): Unit {
        val id = UUID.randomUUID()
        val (old, code) = synchronized(lock) {
            if (closed) return
            mutation = id
            (current to passcode).also { current = null }
        }
        old?.let(::retire)
        val client = create(scope)
        val window = Window(id, client, code)
        val admitted = synchronized(lock) {
            if (closed || mutation != id) false else {
                current = window; focus = null; lastControl = null; controlRevision += 1; true
            }
        }
        if (!admitted) { scope.launch(start = CoroutineStart.UNDISPATCHED) { client.stop() }; return }
        if (!picture.beginSource(id) || !admits(window)) return
        publish(window) { it.copy(phase = RelayViewerPhase.CONNECTING, needsPasscode = false,
            passcodeWasWrong = false, failureReason = null, endedByBroadcaster = false,
            holdsControl = false, controlHolderName = null) }
        synchronized(lock) { if (!closed && current === window) onSourceBegan(id) }
        if (!admits(window)) return
        val reading = scope.launch(start = CoroutineStart.UNDISPATCHED) {
            client.events.collect { event ->
                if (admits(window) && event.source == client.currentSource) receive(window, event)
            }
        }
        synchronized(lock) { if (current === window && !closed) window.events = reading else reading.cancel() }
        if (!admits(window)) return
        client.connect(configuration.host, configuration.port,
            RelayPeerHello(codec.profile.version, configuration.deviceName, passcode = code,
                codecs = if (credentials.jpegOnly) listOf("jpeg") else null, watcherID = configuration.watcherID))
        if (admits(window)) armStall(window)
    }

    private fun receive(window: Window, event: RelayClientEvent<State, Metadata, Control, Denied>): Unit {
        when (event) {
            is RelayClientEvent.Connected -> {
                if (publish(window) { it.copy(phase = RelayViewerPhase.WATCHING, hostName = event.hello.hostName, cameraName = event.hello.cameraName) }) {
                    synchronized(lock) { if (!closed && current === window) onConnected(window.id, event.hello) }
                }
            }
            is RelayClientEvent.StateReceived -> {
                val allows = facts.allowsControlRequests(event.state) ?: policy.legacyAllowsControlRequests
                if (publish(window) { it.copy(state = event.state, allowsControlRequests = allows) }) {
                    synchronized(lock) { if (!closed && current === window) onState(window.id, event.state) }
                }
            }
            is RelayClientEvent.FrameReceived -> {
                val coordinates = facts.focusCoordinates(event.metadata)
                synchronized(lock) {
                    if (!closed && current === window) {
                        window.lastFrameAtMillis = nowMillis()
                        if (coordinates != null) focus = coordinates
                    }
                }
                if (!admits(window)) return
                picture.submit(window.id, event.metadata, event.image)
                if (admits(window) && codec.videoDescription(event.metadata).codec == policy.hevcCodec) armHevc(window)
            }
            is RelayClientEvent.ControlChanged -> {
                val holder = facts.holderName(event.control)
                val held = codec.holderIsRecipient(event.control)
                synchronized(lock) {
                    if (!closed && current === window) {
                        if (lastControl != event.control) controlRevision += 1
                        lastControl = event.control
                        mutableStatus.value = mutableStatus.value.copy(holdsControl = held, controlHolderName = holder)
                    }
                }
            }
            is RelayClientEvent.JoinDenied -> {
                val refusal = facts.refusal(event.denied)
                val watching = synchronized(lock) { current === window && mutableStatus.value.phase == RelayViewerPhase.WATCHING }
                if (watching && !refusal.passcodeRequired) {
                    publish(window) { it.copy(endedByBroadcaster = true, failureReason = refusal.reason, holdsControl = false) }
                    synchronized(lock) { window.rejoin?.cancel(); window.hevc?.cancel(); window.stall?.cancel() }
                } else {
                    publish(window) { it.copy(phase = RelayViewerPhase.DENIED, needsPasscode = refusal.passcodeRequired,
                        passcodeWasWrong = window.passcode != null, failureReason = refusal.reason, holdsControl = false) }
                }
            }
            is RelayClientEvent.Closed -> {
                val before = synchronized(lock) { if (current === window && !closed) mutableStatus.value else null } ?: return
                if (before.endedByBroadcaster) return
                val reason = when (before.phase) {
                    RelayViewerPhase.WATCHING -> event.reason ?: policy.droppedReason
                    RelayViewerPhase.CONNECTING -> event.reason ?: policy.unreachableReason
                    else -> return
                }
                if (publish(window) { it.copy(phase = RelayViewerPhase.FAILED, failureReason = reason, holdsControl = false) }) armRejoin(window)
            }
        }
    }

    public fun submitPasscode(code: String): Unit {
        val trimmed = code.trim()
        synchronized(lock) { if (closed) return; passcode = trimmed }
        credentials.rememberPasscode(configuration.credentialKey, trimmed)
        onPasscodeRemembered(trimmed)
        retry()
    }
    public fun retry(): Unit {
        val window = synchronized(lock) { current?.takeIf { !closed } } ?: return
        retry(window)
    }
    private fun retry(window: Window): Unit {
        scope.launch { if (admits(window)) join() }
    }
    private fun armHevc(window: Window): Unit {
        if (credentials.jpegOnly) return
        val admitted = synchronized(lock) {
            if (closed || current !== window || window.hevcArmed) false else { window.hevcArmed = true; true }
        }
        if (!admitted) return
        val job = scope.launch(start = CoroutineStart.LAZY) {
            val decoded = withTimeoutOrNull(policy.hevcDecodeDeadlineMillis) {
                if (!picture.hasDecoded(window.id)) picture.decodedSources.first { it == window.id }
                Unit
            }
            if (decoded != null || !admits(window) || picture.hasDecoded(window.id)) return@launch
            latchJpeg(window, "no decoded frame within ${policy.hevcDecodeDeadlineMillis} ms; rejoining for JPEG frames")
        }
        if (synchronized(lock) { if (!closed && current === window) { window.hevc = job; true } else false }) job.start()
        else job.cancel()
    }
    private fun latchJpeg(window: Window, reason: String): Unit {
        if (!admits(window) || credentials.jpegOnly) return
        credentials.latchJpegOnly()
        if (!admits(window)) return
        onJpegOnlyLatched()
        if (!admits(window)) return
        log(reason)
        if (admits(window)) retry(window)
    }
    private fun armStall(window: Window): Unit {
        val job = scope.launch(start = CoroutineStart.LAZY) {
            while (admits(window)) {
                delay(minOf(policy.stallPollMillis, policy.stallDeadlineMillis))
                val stalled = synchronized(lock) {
                    !closed && current === window && mutableStatus.value.phase == RelayViewerPhase.WATCHING &&
                        !mutableStatus.value.endedByBroadcaster && nowMillis() - window.lastFrameAtMillis >= policy.stallDeadlineMillis
                }
                if (!stalled) continue
                if (publish(window) { it.copy(phase = RelayViewerPhase.FAILED, failureReason = policy.stalledReason, holdsControl = false) }) armRejoin(window)
                return@launch
            }
        }
        if (synchronized(lock) { if (!closed && current === window) { window.stall = job; true } else false }) job.start()
        else job.cancel()
    }
    private fun armRejoin(window: Window): Unit {
        val admitted = synchronized(lock) { !closed && current === window && window.rejoin?.isActive != true }
        if (!admitted) return
        val job = scope.launch(start = CoroutineStart.LAZY) {
            while (admits(window)) {
                delay(policy.rejoinIntervalMillis)
                val value = synchronized(lock) { if (current === window && !closed) mutableStatus.value else null } ?: return@launch
                if (value.phase != RelayViewerPhase.FAILED || value.endedByBroadcaster) return@launch
                if (value.needsPasscode) continue
                retry(window)
                return@launch
            }
        }
        if (synchronized(lock) { if (!closed && current === window && window.rejoin?.isActive != true) { window.rejoin = job; true } else false }) job.start()
        else job.cancel()
    }

    public fun requestControl(): Boolean = synchronized(lock) {
        val window = current
        if (closed || window == null || mutableStatus.value.phase != RelayViewerPhase.WATCHING || mutableStatus.value.endedByBroadcaster) false
        else window.client.requestControl()
    }
    public fun releaseControl(): Boolean = synchronized(lock) {
        val window = current
        if (closed || window == null || mutableStatus.value.phase != RelayViewerPhase.WATCHING || mutableStatus.value.endedByBroadcaster) false
        else window.client.releaseControl()
    }
    public fun commandAdmission(): RelayViewerCommandAdmission? = synchronized(lock) {
        val window = current
        val value = mutableStatus.value
        if (closed || window == null || value.phase != RelayViewerPhase.WATCHING || !value.holdsControl || value.endedByBroadcaster) null
        else RelayViewerCommandAdmission(window.id, controlRevision, identity)
    }
    public fun sendCommand(command: Command): Boolean {
        val admission = commandAdmission() ?: return false
        return sendCommand(command, admission)
    }
    public fun sendCommand(command: Command, admission: RelayViewerCommandAdmission): Boolean = synchronized(lock) {
        val window = current
        val value = mutableStatus.value
        if (closed || window == null || admission.owner != identity || admission.source != window.id ||
            admission.revision != controlRevision || value.phase != RelayViewerPhase.WATCHING || !value.holdsControl || value.endedByBroadcaster) false
        else window.client.sendCommand(command)
    }
    private fun retire(window: Window): Unit {
        window.events?.cancel(); window.stall?.cancel(); window.hevc?.cancel(); window.rejoin?.cancel()
        scope.launch(start = CoroutineStart.UNDISPATCHED) { window.client.stop() }
        picture.retireSource(window.id)
    }
    public suspend fun stop(): Unit {
        val old = synchronized(lock) {
            if (closed) return
            closed = true; mutation = UUID.randomUUID()
            current.also { current = null; focus = null; mutableStatus.value = mutableStatus.value.copy(holdsControl = false, controlHolderName = null) }
        }
        val stopping = if (old != null) {
            old.events?.cancel(); old.stall?.cancel(); old.hevc?.cancel(); old.rejoin?.cancel()
            scope.launch(start = CoroutineStart.UNDISPATCHED) { old.client.stop() }
        } else null
        picture.close()
        stopping?.join()
    }
}
