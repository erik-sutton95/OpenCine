package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.core.CameraIntegration
import com.opencapture.opencine.core.CameraProfile
import com.opencapture.opencine.core.ConnectTarget
import com.opencapture.opencine.core.CameraServices
import com.opencapture.opencine.core.ConnectedCamera
import com.opencapture.opencine.core.ConnectionAttemptID
import com.opencapture.opencine.core.ConnectionEvent
import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.ConnectionProgress
import com.opencapture.opencine.core.ConnectionPrompt
import com.opencapture.opencine.core.ConnectionStep
import com.opencapture.opencine.core.DiscoveryMode
import com.opencapture.opencine.core.ConfirmationPrompt
import com.opencapture.opencine.core.NearbyCamera
import com.opencapture.opencine.core.RecoveryAction
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.core.SavedRoute
import com.opencapture.opencine.core.UnavailableReason
import java.util.UUID
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.Job
import kotlinx.coroutines.job
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import com.opencapture.opencine.core.CameraSession as CoreCameraSession
import com.opencapture.opencine.core.ConnectionPhase as CorePhase

/** One camera discovery sees (Swift `DiscoveredCamera`). */
data class NikonSighting(val host: String, val name: String?, val source: Source, val heldBy: String? = null) {
    enum class Source { NETWORK, USB, LIVENESS, HELD_BY_ANOTHER_DEVICE }

    val displayName: String get() = name?.takeIf { it.isNotBlank() } ?: "Camera $host"
}

/** The app's connection phases (Swift `CameraConnectionPhase`, without idle, connected and failed). */
enum class NikonConnectionPhase { READY_TO_JOIN, JOINING_WIFI, DISCOVERING, HANDSHAKING, PAIRING, CONFIRM_ON_CAMERA, PREPARING_LIVE_VIEW }

/** One connect the app's connect funnel runs (Swift `NikonConnectRequest`). */
sealed interface NikonConnectRequest {
    /** A saved setup the operator chose, by its record's host and kind. */
    data class Saved(val host: String, val kind: RouteKind) : NikonConnectRequest

    /** A camera discovery sees. [takeOver]: the operator agreed to drop the device holding it. */
    data class Discovered(val sighting: NikonSighting, val takeOver: Boolean) : NikonConnectRequest

    /** A new setup of [kind] for the saved camera whose setup at [anchorHost] names the body. */
    data class AddSetup(val anchorHost: String, val anchorKind: RouteKind, val kind: RouteKind) : NikonConnectRequest
}

/** A connected session and the setup the app saved it under. */
data class NikonConnection(
    val session: CoreCameraSession, val host: String, val kind: RouteKind?,
    val services: CameraServices = CameraServices(),
)

/**
 * What [NikonIntegration] needs from the app's camera pipeline (Swift `NikonConnectPort`): its
 * discovery loop and connect funnel. The app keeps its own save rules; the integration reads the
 * saved setups back as the app stored them.
 */
interface NikonConnectPort {
    /** The latest discovery pass's cameras. */
    val sightings: StateFlow<List<NikonSighting>>

    /** The phase of the connect in flight with the app's live line; `null` between connects. */
    val phase: StateFlow<Pair<NikonConnectionPhase, String?>?>

    /** The saved setups as the app stores them ([NikonSavedRecordsV0] JSON); `null` when none. */
    fun savedRecords(): String?

    /** Runs discovery in [mode] until [stopDiscovery]: passive never dials a control port. */
    fun startDiscovery(mode: DiscoveryMode)
    fun stopDiscovery()

    /** The app's connect funnel; throws a failure ([NikonConnectException]) or cancels. */
    suspend fun connect(request: NikonConnectRequest): NikonConnection
    /** Resumes the current request after explicit operator consent; legacy ports keep their admission. */
    suspend fun connect(request: NikonConnectRequest, takingOverConfirmed: Boolean): NikonConnection = connect(request)

    fun cancel()

    /** The app's forget for these setups: records, paired-host memory and the access point's key. */
    fun forget(hosts: List<String>)

    /**
     * The device holding [host] right now ([NikonDiscovery.currentHolder]), asked before a saved
     * setup dials: the camera does not refuse a second initiator, it drops the first. `null` when
     * no device says it holds it; ports without a presence lookup keep their own admission.
     */
    suspend fun currentHolder(host: String): String? = null
}

/** A connect failure the app typed, with its operator copy. */
class NikonConnectException(val failure: ConnectionFailure) : Exception(failure.message)

/**
 * Connecting would drop another device's live session on this camera (Swift `NikonTakeOverPrompt`).
 */
data class NikonTakeOverPrompt(
    val camera: String,
    val holder: String?,
    override val confirm: () -> Unit,
    override val cancel: () -> Unit,
    private val message: String? = null,
) : ConfirmationPrompt {
    override val confirmationID: String = UUID.randomUUID().toString()
    override val confirmationTitle: String = "Take over this camera?"
    override val confirmTitle: String = "Take Over"
    override val cancelTitle: String = "Cancel"
    override val fallbackText: String get() = message ?: message(holder)

    companion object {
        /** Names the device whose session would be displaced by this operator action. */
        fun message(holder: String?): String = holder?.takeIf(String::isNotBlank)?.let {
            "$it is using this camera. Connecting will disconnect it."
        } ?: "Another device is using this camera. Connecting will disconnect it."
    }
}

/**
 * The Nikon [com.opencapture.opencine.core.CameraIntegration] (Swift `NikonIntegration`): passive
 * discovery for the cameras list and active discovery for pairing, one connect at a time through
 * the app's funnel, the card's steps from the app's phases, approve-on-camera and network-join
 * prompts, a take-over prompt before connecting to a held camera, and forget. Collect on the main
 * thread.
 */
class NikonIntegration(private val port: NikonConnectPort) : CameraIntegration {
    override val id = NikonOpenCineSession.INTEGRATION
    override val profiles: List<CameraProfile> = listOf(
        CameraProfile(
            "${id.rawValue}.z", "Nikon Z", RouteKind.entries.toSet(),
            setOf(RouteKind.CAMERA_ACCESS_POINT, RouteKind.INFRASTRUCTURE_NETWORK, RouteKind.PHONE_HOTSPOT, RouteKind.USB),
        ),
    )
    override val discoveryModes: Set<DiscoveryMode> = setOf(DiscoveryMode.PASSIVE, DiscoveryMode.ACTIVE)

    private val listeners = mutableListOf<DiscoveryMode>()
    private var running: DiscoveryMode? = null
    private var currentConnect: Job? = null

    // Discovery

    override fun discover(mode: DiscoveryMode): Flow<List<NearbyCamera>> {
        if (mode !in discoveryModes) return emptyFlow()
        return flow {
            listeners += mode
            updateDiscovery()
            try {
                emitAll(port.sightings.map { nearby(it) })
            } finally {
                listeners.remove(mode)
                updateDiscovery()
            }
        }
    }

    /** Active while any listener asks for it, else passive; stopped with no listener. */
    private fun updateDiscovery() {
        val wanted = when {
            listeners.isEmpty() -> null
            DiscoveryMode.ACTIVE in listeners -> DiscoveryMode.ACTIVE
            else -> DiscoveryMode.PASSIVE
        }
        if (wanted == running) return
        running = wanted
        if (wanted == null) port.stopDiscovery() else port.startDiscovery(wanted)
    }

    /**
     * A saved setup's sighting names its camera and the setup it reaches; a liveness answer only
     * ever lights a saved camera.
     */
    private fun nearby(sightings: List<NikonSighting>): List<NearbyCamera> {
        val cameras = NikonSavedRecordsV0.read(port.savedRecords() ?: "[]")?.let(NikonSavedRecordsV0::layout).orEmpty()
        return sightings.mapNotNull { sighting ->
            val name = nikonAssignedName(sighting.displayName)
            val saved = cameras.firstOrNull { placed ->
                placed.members.any { (record, _) ->
                    record.host.equals(sighting.host, ignoreCase = true) ||
                        (name != null && nikonAssignedName(record.cameraName) == name)
                }
            }?.camera
            if (saved == null && sighting.source == NikonSighting.Source.LIVENESS) return@mapNotNull null
            val usb = sighting.source == NikonSighting.Source.USB
            NearbyCamera(
                sighting.host, savedID = saved?.id, name = sighting.displayName, model = "",
                routes = setOf(if (usb) RouteKind.USB else RouteKind.INFRASTRUCTURE_NETWORK),
                availability = if (sighting.source == NikonSighting.Source.HELD_BY_ANOTHER_DEVICE) {
                    Availability.Unavailable(UnavailableReason.Busy)
                } else {
                    Availability.Available
                },
                routeKey = saved?.let { reachedRoute(it, sighting.host, usb) },
            )
        }
    }

    // Connecting

    override fun connect(target: ConnectTarget): Flow<ConnectionEvent> = channelFlow {
        val request: NikonConnectRequest
        val device: String
        var network: String? = null
        val previous: SavedCamera?
        when (target) {
            is ConnectTarget.Saved -> {
                val route = target.camera.routes.firstOrNull { it.id == target.route }
                val host = route?.extras?.get(NikonSavedRecordsV0.Extra.HOST)
                if (route == null || host == null) {
                    send(ConnectionEvent.Failed(failure(ConnectionFailure.Reason.Unsupported, "route.unsupported", "This setup can no longer be reached.")))
                    return@channelFlow
                }
                request = NikonConnectRequest.Saved(host, route.kind)
                device = target.camera.displayName
                network = route.network
                previous = target.camera
            }
            is ConnectTarget.Nearby -> {
                val sighting = port.sightings.value.firstOrNull { it.host == target.camera.id }
                    ?: NikonSighting(
                        target.camera.id, target.camera.name,
                        if (RouteKind.USB in target.camera.routes) NikonSighting.Source.USB else NikonSighting.Source.NETWORK,
                    )
                request = NikonConnectRequest.Discovered(sighting, takeOver = false)
                device = sighting.displayName
                previous = null
            }
            is ConnectTarget.AddRoute -> {
                val anchor = target.camera.routes.firstOrNull { it.id == target.camera.preferredRoute } ?: target.camera.routes.firstOrNull()
                val host = anchor?.extras?.get(NikonSavedRecordsV0.Extra.HOST)
                if (anchor == null || host == null || target.draft.kind == RouteKind.CAPTURE_DEVICE) {
                    send(ConnectionEvent.Failed(failure(ConnectionFailure.Reason.Unsupported, "route.unsupported", "This setup cannot be added.")))
                    return@channelFlow
                }
                request = NikonConnectRequest.AddSetup(host, anchor.kind, target.draft.kind)
                device = target.camera.displayName
                previous = target.camera
            }
        }
        val attempt = ConnectionAttemptID()
        val plan = plan(request)
        val owner = currentCoroutineContext().job
        val previousProducer = currentConnect
        currentConnect = owner
        previousProducer?.cancel()
        try {
            suspend fun admitCurrent() {
                currentCoroutineContext().ensureActive()
                if (currentConnect !== owner) throw CancellationException("Connection source retired")
            }
            var connecting = request
            var waitingForConsent = false
            suspend fun consent(holder: String?, message: String? = null): Boolean {
                waitingForConsent = true
                val decision = CompletableDeferred<Boolean>()
                val prompt = NikonTakeOverPrompt(
                    device, holder, confirm = { decision.complete(true) }, cancel = { decision.complete(false) }, message = message,
                )
                send(ConnectionEvent.Progress(ConnectionProgress(attempt, CorePhase.NEGOTIATING, plan.map { it.first }, 0), ConnectionPrompt.Integration(prompt)))
                val approved = decision.await()
                admitCurrent()
                waitingForConsent = false
                return approved
            }
            var savedTakeOverConfirmed = false
            if (request is NikonConnectRequest.Discovered && request.sighting.source == NikonSighting.Source.HELD_BY_ANOTHER_DEVICE) {
                if (!consent(request.sighting.heldBy)) return@channelFlow
                connecting = request.copy(takeOver = true)
            } else if (request is NikonConnectRequest.Saved) {
                // Ask before the first dial: the body hands its session to us and drops the device
                // holding it, so a refusal after the fact never comes (physical-C C9, ZR).
                val holder = port.currentHolder(request.host)
                admitCurrent()
                if (holder != null) {
                    if (!consent(holder.ifBlank { null })) return@channelFlow
                    savedTakeOverConfirmed = true
                }
            }
            suspend fun connectWithConsent(): NikonConnection? {
                try {
                    admitCurrent()
                    return if (savedTakeOverConfirmed) port.connect(connecting, takingOverConfirmed = true)
                        else port.connect(connecting)
                } catch (error: NikonConnectException) {
                    if (savedTakeOverConfirmed || request !is NikonConnectRequest.Saved ||
                        error.failure.reason != ConnectionFailure.Reason.HeldElsewhere) throw error
                    if (!consent(null, error.failure.message)) return null
                    // Only this live coroutine can reach the confirmed overload, once. A failure
                    // from it escapes to the terminal failure handler rather than asking again.
                    admitCurrent()
                    return port.connect(connecting, takingOverConfirmed = true)
                }
            }
            var outcome: ConnectionEvent? = null
            val phases = launch {
                var last: Pair<ConnectionProgress, String?>? = null
                port.phase.collect { value ->
                    if (waitingForConsent) return@collect
                    val (phase, detail) = value ?: return@collect
                    val text = detail?.takeIf { it.isNotEmpty() } ?: defaultText(phase, device)
                    val (core, prompt) = when (phase) {
                        NikonConnectionPhase.READY_TO_JOIN, NikonConnectionPhase.JOINING_WIFI ->
                            CorePhase.JOINING_NETWORK to ConnectionPrompt.AcceptNetworkJoin(network ?: device, text)
                        NikonConnectionPhase.DISCOVERING -> CorePhase.LINK to null
                        NikonConnectionPhase.HANDSHAKING, NikonConnectionPhase.PREPARING_LIVE_VIEW -> CorePhase.NEGOTIATING to null
                        NikonConnectionPhase.PAIRING, NikonConnectionPhase.CONFIRM_ON_CAMERA ->
                            CorePhase.AWAITING_APPROVAL to ConnectionPrompt.ApproveOnCamera(text)
                    }
                    val step = plan.indexOfFirst { phase in it.second }.takeIf { it >= 0 } ?: last?.first?.current ?: 0
                    val progress = ConnectionProgress(attempt, core, plan.map { it.first }, step, if (prompt == null) text else null)
                    if (last == progress to prompt?.text) return@collect
                    last = progress to prompt?.text
                    send(ConnectionEvent.Progress(progress, prompt))
                }
            }
            try {
                val connection = connectWithConsent() ?: return@channelFlow
                admitCurrent()
                outcome = ConnectionEvent.Connected(ConnectedCamera(record(previous, connection, device), connection.session, connection.services))
            } catch (error: NikonConnectException) {
                outcome = ConnectionEvent.Failed(error.failure)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                outcome = ConnectionEvent.Failed(failure(ConnectionFailure.Reason.Other, "connect.failed", error.message ?: "The camera did not connect."))
            } finally {
                phases.cancel()
                // The consumer stopped listening before an outcome: cancel the attempt.
                if (outcome == null && currentConnect === owner) port.cancel()
            }
            send(outcome!!)
        } finally {
            // A retired producer never cancels the port now owned by its successor.
            if (currentConnect === owner) currentConnect = null
        }
    }

    override suspend fun forget(camera: SavedCamera) {
        port.forget(camera.routes.mapNotNull { it.extras[NikonSavedRecordsV0.Extra.HOST] })
    }

    /**
     * The saved camera the app's save rules produced for this session, read back from its records;
     * route ids the attempt's camera already had are kept.
     */
    private fun record(previous: SavedCamera?, connection: NikonConnection, device: String): SavedCamera {
        val cameras = NikonSavedRecordsV0.read(port.savedRecords() ?: "[]")?.let(NikonSavedRecordsV0::layout).orEmpty().map { it.camera }
        val matches = { route: SavedRoute ->
            route.extras[NikonSavedRecordsV0.Extra.HOST].equals(connection.host, ignoreCase = true) &&
                (connection.kind == null || connection.kind == route.kind)
        }
        val camera = cameras.firstOrNull { camera -> camera.routes.any(matches) }
            ?: return previous ?: SavedCamera(
                id = connection.host, integration = id, advertisedName = device, model = "",
                routes = listOf(SavedRoute(key = connection.host, kind = connection.kind ?: RouteKind.INFRASTRUCTURE_NETWORK, extras = mapOf(NikonSavedRecordsV0.Extra.HOST to connection.host))),
            )
        val routes = camera.routes.map { route ->
            previous?.routes?.firstOrNull { it.key == route.key }?.let { route.copy(id = it.id) } ?: route
        }
        return camera.copy(routes = routes, preferredRoute = routes.firstOrNull(matches)?.id ?: camera.preferredRoute)
    }

    companion object {
        /**
         * The key of the saved setup a sighting at [host] reaches: the one at that address, else a
         * cable's USB setup. Never an access point setup: its fixed address answering off the
         * camera's own network is no proof of that network.
         */
        private fun reachedRoute(camera: SavedCamera, host: String, usb: Boolean): String? = camera.routes.firstOrNull { route ->
            route.kind != RouteKind.CAMERA_ACCESS_POINT &&
                (route.extras[NikonSavedRecordsV0.Extra.HOST].equals(host, ignoreCase = true) || (usb && route.kind == RouteKind.USB))
        }?.key

        fun failure(reason: ConnectionFailure.Reason, code: String, message: String): ConnectionFailure = ConnectionFailure(
            reason, null, "Couldn't connect", message,
            if (reason == ConnectionFailure.Reason.Permission(ConnectionFailure.Permission.LOCAL_NETWORK)) {
                listOf(RecoveryAction.OpenSettings, RecoveryAction.Retry)
            } else {
                listOf(RecoveryAction.Retry)
            },
            "${NikonOpenCineSession.INTEGRATION.rawValue}.$code",
        )

        /** The card's plan for a request; each step lists the app phases it covers. */
        fun plan(request: NikonConnectRequest): List<Pair<ConnectionStep, Set<NikonConnectionPhase>>> {
            val join = ConnectionStep("Joining the camera’s Wi-Fi") to setOf(NikonConnectionPhase.READY_TO_JOIN, NikonConnectionPhase.JOINING_WIFI)
            val find = ConnectionStep("Finding the camera") to setOf(NikonConnectionPhase.DISCOVERING)
            val connect = ConnectionStep("Connecting") to setOf(NikonConnectionPhase.HANDSHAKING)
            val pair = ConnectionStep("Pairing") to setOf(NikonConnectionPhase.PAIRING, NikonConnectionPhase.CONFIRM_ON_CAMERA)
            val live = ConnectionStep("Starting live view") to setOf(NikonConnectionPhase.PREPARING_LIVE_VIEW)
            return when (request) {
                is NikonConnectRequest.Saved -> if (request.kind == RouteKind.CAMERA_ACCESS_POINT) listOf(join, find, connect, live) else listOf(find, connect, live)
                is NikonConnectRequest.Discovered -> listOf(connect, pair, live)
                is NikonConnectRequest.AddSetup -> listOf(
                    ConnectionStep("Waiting for the camera on ${label(request.kind)}") to
                        setOf(NikonConnectionPhase.DISCOVERING, NikonConnectionPhase.READY_TO_JOIN, NikonConnectionPhase.JOINING_WIFI),
                    connect, live,
                )
            }
        }

        private fun label(kind: RouteKind): String = when (kind) {
            RouteKind.CAMERA_ACCESS_POINT -> "its Wi-Fi"
            RouteKind.INFRASTRUCTURE_NETWORK -> "Wi-Fi"
            RouteKind.PHONE_HOTSPOT -> "your hotspot"
            RouteKind.USB -> "USB-C"
            RouteKind.CAPTURE_DEVICE -> "HDMI"
        }

        /** The progress sheet's detail line when the app sends none (Swift `ConnectionProgressCopy.statusDetail`). */
        fun defaultText(phase: NikonConnectionPhase, device: String): String = when (phase) {
            NikonConnectionPhase.READY_TO_JOIN -> "Join $device's Wi‑Fi network to continue."
            NikonConnectionPhase.JOINING_WIFI -> "Approve the network request to switch networks."
            NikonConnectionPhase.DISCOVERING -> "Looking for $device on your network."
            NikonConnectionPhase.HANDSHAKING -> "Establishing a secure link with $device."
            NikonConnectionPhase.PAIRING -> "Confirm the pairing request on $device."
            NikonConnectionPhase.CONFIRM_ON_CAMERA -> "Tap “Confirm” on $device. It will restart its Wi‑Fi, then this phone reconnects."
            NikonConnectionPhase.PREPARING_LIVE_VIEW -> "Opening the live monitor for $device."
        }
    }
}
