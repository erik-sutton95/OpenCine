package com.opencapture.opencine.core.testing

import com.opencapture.opencine.core.CameraIntegration
import com.opencapture.opencine.core.CameraProfile
import com.opencapture.opencine.core.CameraServices
import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.ConnectTarget
import com.opencapture.opencine.core.ConnectedCamera
import com.opencapture.opencine.core.ConnectionAttemptID
import com.opencapture.opencine.core.ConnectionEvent
import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.ConnectionPhase
import com.opencapture.opencine.core.ConnectionProgress
import com.opencapture.opencine.core.ConnectionPrompt
import com.opencapture.opencine.core.ConnectionStep
import com.opencapture.opencine.core.DiscoveryMode
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.IntegrationPresentation
import com.opencapture.opencine.core.NearbyCamera
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.core.SavedRoute
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf

/**
 * A scripted [CameraIntegration] (Swift `FakeIntegration`). Tests publish nearby lists, drive each
 * attempt and read what discovery dialled. Discovery dials every endpoint for presence;
 * [DiscoveryMode.ACTIVE] also dials its control port, so a passive run never logs a
 * [DialPurpose.CAMERA_CONTROL] dial. Confined to one thread, like [FakeCameraSession].
 *
 * Flows are cold: discovery and an attempt start when collected (Swift: when called).
 */
public class FakeIntegration(
    override val id: IntegrationID = IntegrationID("test.fake-integration"),
    override val profiles: List<CameraProfile> = listOf(
        CameraProfile(
            "test.fake-integration.body", "Test Body",
            setOf(RouteKind.CAMERA_ACCESS_POINT, RouteKind.INFRASTRUCTURE_NETWORK),
            setOf(RouteKind.INFRASTRUCTURE_NETWORK),
        ),
    ),
    override val discoveryModes: Set<DiscoveryMode> = setOf(DiscoveryMode.PASSIVE, DiscoveryMode.ACTIVE),
    /** The plan every attempt reports. */
    public var steps: List<ConnectionStep> = listOf(
        ConnectionStep("Link"), ConnectionStep("Approve"), ConnectionStep("Join network"), ConnectionStep("Video"),
    ),
    /** Hosts discovery dials. */
    public var endpoints: List<String> = emptyList(),
    override val presentation: IntegrationPresentation = IntegrationPresentation(),
    /** What discovery reports about running; `flowOf(false)` scripts a blocked radio (IA-336). */
    override val discoveryRunning: Flow<Boolean> = flowOf(true),
) : CameraIntegration {
    /**
     * Called with each new attempt when its flow is collected: a SIMULATED app answers every
     * connect here (`attempt.connect(session)`) instead of scripting it from a test.
     */
    public var onAttempt: ((FakeAttempt) -> Unit)? = null

    public enum class DialPurpose {
        /** Reachability only; cannot reach a camera's control service. */
        PRESENCE,
        CAMERA_CONTROL,
    }

    public data class Dial(public val endpoint: String, public val purpose: DialPurpose)

    private val dialLog = mutableListOf<Dial>()
    private val started = mutableListOf<DiscoveryMode>()
    private val live = mutableListOf<DiscoveryMode>()
    private val attemptLog = mutableListOf<FakeAttempt>()
    private val forgetLog = mutableListOf<SavedCamera>()
    private val nearby = MutableStateFlow<List<NearbyCamera>>(emptyList())

    public val dials: List<Dial> get() = dialLog.toList()

    /** Modes discovery started with, in order. */
    public val discoveries: List<DiscoveryMode> get() = started.toList()

    /** Modes of the discovery runs whose collector is still collecting. */
    public val liveDiscoveries: List<DiscoveryMode> get() = live.toList()
    public val attempts: List<FakeAttempt> get() = attemptLog.toList()
    public val forgotten: List<SavedCamera> get() = forgetLog.toList()

    /** The attempt for a camera that is still running, if any. */
    public fun liveAttempt(cameraID: String): FakeAttempt? =
        attemptLog.lastOrNull { it.target.cameraID == cameraID && it.end == null }

    /** Replaces the nearby list; every live discovery run gets it. */
    public fun publish(list: List<NearbyCamera>) {
        nearby.value = list
    }

    override fun discover(mode: DiscoveryMode): Flow<List<NearbyCamera>> {
        if (mode !in discoveryModes) return emptyFlow()
        return flow {
            started += mode
            for (endpoint in endpoints) {
                dialLog += Dial(endpoint, DialPurpose.PRESENCE)
                if (mode == DiscoveryMode.ACTIVE) dialLog += Dial(endpoint, DialPurpose.CAMERA_CONTROL)
            }
            live += mode
            try {
                emitAll(nearby)
            } finally {
                live.remove(mode)
            }
        }
    }

    override fun connect(target: ConnectTarget): Flow<ConnectionEvent> = flow {
        val channel = Channel<ConnectionEvent>(Channel.UNLIMITED)
        liveAttempt(target.cameraID)?.finish(FakeAttempt.End.SUPERSEDED)
        val attempt = FakeAttempt(id, target, steps, channel)
        attemptLog += attempt
        onAttempt?.invoke(attempt)
        try {
            for (event in channel) emit(event)
        } finally {
            attempt.finish(FakeAttempt.End.CANCELLED)
        }
    }

    override suspend fun forget(camera: SavedCamera) {
        forgetLog += camera
    }
}

/**
 * One scripted attempt. Its events reach the collector only while it is live: once it is
 * connected, failed, cancelled by the collector or superseded by a newer attempt for the same
 * camera, everything it tries to emit is dropped.
 */
public class FakeAttempt internal constructor(
    private val integration: IntegrationID,
    public val target: ConnectTarget,
    public val steps: List<ConnectionStep>,
    private val channel: Channel<ConnectionEvent>,
) {
    public enum class End {
        CONNECTED,
        FAILED,

        /** The collector stopped collecting. */
        CANCELLED,

        /** A newer attempt for the same camera started. */
        SUPERSEDED,
    }

    public val id: ConnectionAttemptID = ConnectionAttemptID()

    /** `null` while the attempt runs. */
    public var end: End? = null
        private set

    /** Events this attempt tried to emit after it ended (what a late callback would do). */
    public var dropped: Int = 0
        private set

    public fun progress(phase: ConnectionPhase, step: Int, prompt: ConnectionPrompt? = null, note: String? = null) {
        emit(ConnectionEvent.Progress(ConnectionProgress(id, phase, steps, step, note), prompt))
    }

    /** Connects with [saved], else the record a first connect would build from the target. */
    public fun connect(session: CameraSession, saved: SavedCamera? = null, services: CameraServices = CameraServices()) {
        if (emit(ConnectionEvent.Connected(ConnectedCamera(saved ?: defaultRecord(), session, services)))) {
            finish(End.CONNECTED)
        }
    }

    public fun fail(failure: ConnectionFailure) {
        if (emit(ConnectionEvent.Failed(failure))) finish(End.FAILED)
    }

    internal fun finish(end: End) {
        if (this.end == null) this.end = end
        channel.close()
    }

    private fun emit(event: ConnectionEvent): Boolean {
        if (end != null || channel.trySend(event).isFailure) {
            dropped += 1
            return false
        }
        return true
    }

    private fun defaultRecord(): SavedCamera = when (target) {
        is ConnectTarget.Saved -> target.camera
        is ConnectTarget.AddRoute -> target.camera
        is ConnectTarget.Nearby -> SavedCamera(
            id = target.camera.savedID ?: target.camera.id,
            integration = integration,
            advertisedName = target.camera.name,
            model = target.camera.model,
            routes = RouteKind.entries.filter { it in target.camera.routes }.map { SavedRoute(key = it.rawValue, kind = it) },
        )
    }
}
