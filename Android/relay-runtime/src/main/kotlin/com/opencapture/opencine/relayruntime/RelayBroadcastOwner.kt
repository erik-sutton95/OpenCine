package com.opencapture.opencine.relayruntime

import com.opencapture.opencine.relay.RelayControlWireCodec
import com.opencapture.opencine.relay.RelayEncoderProfile
import com.opencapture.opencine.relay.RelayHostControl
import com.opencapture.opencine.relay.RelaySocketPolicy
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** Facts rendered by the common sharing controls. */
public data class RelayBroadcastStatus(
    public val isBroadcasting: Boolean = false,
    public val watcherCount: Int = 0,
    public val pendingControlRequestName: String? = null,
    public val controlHolderName: String? = null,
    public val failureReason: String? = null,
    public val pendingControlRequest: RelayHostControl.PendingRequest? = null,
)

/** Encoded picture bytes remain owned by the source; a JPEG need not be decoded and re-encoded. */
public data class RelayBroadcastFrame<Metadata>(
    public val metadata: Metadata,
    public val image: ByteArray,
    public val measuredFramesPerSecond: Double? = null,
)

/** A bounded SDK port. Each broadcast window owns a distinct announcement instance. */
public interface RelayBroadcastAnnouncement {
    public fun start(port: Int, servedCameraHost: String?): Unit
    public fun stop(): Unit
}

/** One authority captured before entering the camera's own queued/native boundary. */
public class RelayBroadcastDispatch internal constructor(
    public val receipt: RelayHostControl.Admission,
    private val current: () -> Boolean,
) {
    public fun isCurrent(): Boolean = runCatching(current).getOrDefault(false)
}

/** Owns the actual host, subscriptions, announcements and command source lifetime.
 * Camera readout/wire conversion and the camera's native operation admission are bounded ports.
 */
public class RelayBroadcastOwner<Source : Any, Input, State, Metadata, Command, Control, Denied>(
    private val scope: CoroutineScope,
    private val codec: RelayControlWireCodec<State, Metadata, Command, Control, Denied>,
    private val hostName: String,
    private val frames: (Source) -> Flow<Input>,
    private val stateChanges: (Source) -> Flow<Unit>,
    private val frame: (Input) -> RelayBroadcastFrame<Metadata>,
    private val readState: (Source, Double?, Boolean) -> State,
    private val dispatch: suspend (Source, Command, RelayBroadcastDispatch) -> Unit,
    private val makeAnnouncement: () -> RelayBroadcastAnnouncement,
    private val sockets: RelaySocketFactory = JdkRelaySocketFactory(),
    private val policy: RelaySocketPolicy = RelaySocketPolicy(),
    private val frameDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val loadPreferredPort: () -> Int = { 0 },
    private val savePreferredPort: (Int) -> Unit = {},
    private val onListening: (Int) -> Unit = {},
    private val onCommandRefused: (Command) -> Unit = {},
) {
    private val lock: Any = Any()
    private val mutableStatus: MutableStateFlow<RelayBroadcastStatus> = MutableStateFlow(RelayBroadcastStatus())
    public val status: StateFlow<RelayBroadcastStatus> = mutableStatus.asStateFlow()
    public val pendingRequest: RelayHostControl.PendingRequest? get() = status.value.pendingControlRequest
    private inner class Window(
        val source: Source,
        val host: RelaySocketHost<State, Metadata, Command, Control, Denied>,
        val announcement: RelayBroadcastAnnouncement,
    ) {
        var framePump: Job? = null
        var statePump: Job? = null
        @Volatile var latestFPS: Double? = null
    }
    private var window: Window? = null
    private var mutation: UUID = UUID.randomUUID()
    public var watcherPasscode: String = ""
        set(value) {
            field = value
            current()?.host?.watcherPasscode = value
        }
    public var encoderProfile: RelayEncoderProfile = RelayEncoderProfile.LOW_LATENCY
        set(value) {
            field = value
            current()?.host?.encoderProfile = value
        }
    public var allowsControlRequests: Boolean = true
        set(value) {
            field = value
            val target = current() ?: return
            target.host.allowsControlRequests = value
            scope.launch {
                if (!owns(target)) return@launch
                if (!value) target.host.declinePendingControl()
                if (owns(target)) publishState(target)
            }
        }

    public fun start(source: Source, cameraName: String?, servedCameraHost: String?): Boolean {
        stop("The broadcast ended.")
        val revision = synchronized(lock) { if (window != null) return false else mutation }
        val host = RelaySocketHost(scope, codec, hostName, cameraName, sockets, policy)
        val target = Window(source, host, makeAnnouncement())
        val installed = synchronized(lock) {
            if (window != null || mutation != revision) false else {
                window = target
                mutation = UUID.randomUUID()
                true
            }
        }
        if (!installed) {
            target.announcement.stop()
            return false
        }
        host.watcherPasscode = watcherPasscode
        host.allowsControlRequests = allowsControlRequests
        host.encoderProfile = encoderProfile
        host.onPeerCountChanged = { count -> update(target) { it.copy(watcherCount = count) } }
        host.onControlChanged = { pending, holder ->
            val request = host.pendingRequest
            update(target) { it.copy(pendingControlRequestName = pending, controlHolderName = holder,
                pendingControlRequest = request) }
        }
        host.onFailure = { reason -> update(target) { it.copy(failureReason = reason) } }
        host.onCommand = { command, receipt ->
            val admission = RelayBroadcastDispatch(receipt) { owns(target) && host.admits(receipt) }
            // Jobs accepted into native noncancellable I/O finish there. Retirement instead
            // revokes their predicate, refusing every waiter at its actual dispatch boundary.
            scope.launch {
                if (!admission.isCurrent()) return@launch
                runCatching { dispatch(target.source, command, admission) }.onFailure {
                    if (owns(target)) onCommandRefused(command)
                }
            }
        }
        val preferredPort = loadPreferredPort()
        if (!owns(target)) return false
        if (!host.start(preferredPort)) {
            retire(target, null, clearStatus = false)
            return false
        }
        if (!owns(target)) {
            dispose(target, null)
            return false
        }
        val port = host.boundPort
        savePreferredPort(port)
        if (!owns(target)) return false
        onListening(port)
        if (!owns(target)) return false
        target.announcement.start(port, servedCameraHost)
        if (!owns(target)) {
            target.announcement.stop()
            return false
        }
        target.framePump = scope.launch(frameDispatcher, start = CoroutineStart.LAZY) {
            frames(target.source).collect { input ->
                if (!owns(target)) return@collect
                val encoded = frame(input)
                if (!owns(target)) return@collect
                target.latestFPS = encoded.measuredFramesPerSecond
                host.broadcastFrame(encoded.metadata, encoded.image)
            }
        }
        target.statePump = scope.launch(start = CoroutineStart.LAZY) {
            stateChanges(target.source).collect { if (owns(target)) publishState(target) }
        }
        if (!owns(target)) {
            target.framePump?.cancel()
            target.statePump?.cancel()
            return false
        }
        update(target) { it.copy(isBroadcasting = true) }
        target.framePump?.start()
        target.statePump?.start()
        scope.launch { if (owns(target)) publishState(target) }
        return owns(target)
    }

    public fun grantPendingControl(): Unit = control { it.grantPendingControl() }
    public fun declinePendingControl(): Unit = control { it.declinePendingControl() }
    public fun grantPendingControl(request: RelayHostControl.PendingRequest): Unit = pendingControl(request) {
        it.grantPendingControl(request)
    }
    public fun declinePendingControl(request: RelayHostControl.PendingRequest): Unit = pendingControl(request) {
        it.declinePendingControl(request)
    }
    private fun pendingControl(
        request: RelayHostControl.PendingRequest,
        action: suspend (RelaySocketHost<State, Metadata, Command, Control, Denied>) -> Unit,
    ): Unit {
        val target = current() ?: return
        if (target.host.pendingRequest != request || !owns(target)) return
        scope.launch { if (owns(target)) action(target.host) }
    }
    public fun reclaimControl(): Unit = control { it.reclaimControl() }
    private fun control(action: suspend (RelaySocketHost<State, Metadata, Command, Control, Denied>) -> Unit): Unit {
        val target = current() ?: return
        scope.launch { if (owns(target)) action(target.host) }
    }
    public fun stop(notifyReason: String? = null): Unit {
        val target = current()
        if (target == null) {
            synchronized(lock) {
                if (window == null) {
                    mutation = UUID.randomUUID()
                    mutableStatus.value = RelayBroadcastStatus()
                }
            }
            return
        }
        retire(target, notifyReason, clearStatus = true)
    }
    private fun retire(target: Window, reason: String?, clearStatus: Boolean): Unit {
        synchronized(lock) {
            if (window !== target) return
            window = null
            mutation = UUID.randomUUID()
            if (clearStatus) mutableStatus.value = RelayBroadcastStatus()
        }
        dispose(target, reason)
    }
    private fun dispose(target: Window, reason: String?): Unit {
        target.framePump?.cancel()
        target.statePump?.cancel()
        target.announcement.stop()
        // Retire host authority immediately, before the courtesy close's suspension.
        scope.launch(start = CoroutineStart.UNDISPATCHED) { target.host.stop(reason) }
    }
    private suspend fun publishState(target: Window): Unit {
        if (!owns(target)) return
        val state = readState(target.source, target.latestFPS, allowsControlRequests)
        if (owns(target)) target.host.broadcastState(state)
    }
    private fun current(): Window? = synchronized(lock) { window }
    private fun owns(target: Window): Boolean = synchronized(lock) { window === target }
    private fun update(target: Window, change: (RelayBroadcastStatus) -> RelayBroadcastStatus): Unit {
        synchronized(lock) { if (window === target) mutableStatus.value = change(mutableStatus.value) }
    }
}
