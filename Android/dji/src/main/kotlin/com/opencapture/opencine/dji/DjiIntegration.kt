package com.opencapture.opencine.dji

import com.opencapture.opencine.core.CameraIntegration
import com.opencapture.opencine.core.CameraProfile
import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.ConnectTarget
import com.opencapture.opencine.core.ConnectedCamera
import com.opencapture.opencine.core.ConnectionAttemptID
import com.opencapture.opencine.core.ConnectionEvent
import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.ConnectionProgress
import com.opencapture.opencine.core.ConnectionPrompt
import com.opencapture.opencine.core.ConnectionStep
import com.opencapture.opencine.core.DiscoveryMode
import com.opencapture.opencine.core.NearbyCamera
import com.opencapture.opencine.core.RecoveryAction
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.core.SavedRoute
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import com.opencapture.opencine.core.ConnectionPhase as CorePhase

/**
 * What [DjiIntegration] needs from the DJI session (Swift `DJIConnectPort`): Bluetooth discovery,
 * the setup for the next connect, one connection, its core session. [PocketCameraSession] is the
 * one implementation; tests script a fake.
 */
interface DjiConnectPort {
    val found: StateFlow<List<FoundCamera>>
    val phaseFlow: StateFlow<ConnectionPhase>
    /** Live setup text, for example "Finding the camera on <network>". */
    val setupProgress: StateFlow<String?>
    /** Why the last connect failed, typed; `null` while none has. */
    val failureDetail: StateFlow<ConnectionFailure?>
    val joinedSSID: String?
    val control: CameraSession
    fun startScan()
    fun stopScan()
    fun useSetup(setup: CameraConnectionSetup, network: MultiviewNetworkStore.Network?, restoreAccessPoint: Boolean)
    /** Connects the camera now when it is nearby, else scans for it and connects when it appears. */
    fun reconnect(id: String)
    fun disconnect()
}

/** DJI connection failures with the session's own copy (Swift: the app's typed errors). */
object DjiFailures {
    private fun failure(reason: ConnectionFailure.Reason, code: String, message: String, phase: CorePhase?) =
        ConnectionFailure(
            reason, phase, "Couldn’t connect over Camera Wi-Fi", message, listOf(RecoveryAction.Retry),
            "${DjiCameraSessionAdapter.INTEGRATION.rawValue}.$code",
        )

    /** A connect that threw [error] in [phase]; [message] is the copy the session shows. */
    fun classify(error: Throwable?, phase: ConnectionPhase, message: String): ConnectionFailure {
        val core = corePhase(phase)
        val lower = message.lowercase()
        return when {
            error is DatalinkHandshakeException -> failure(ConnectionFailure.Reason.TimedOut, "datalink.silent", message, core)
            error is StationJoin.Failure.JoinRejected -> failure(ConnectionFailure.Reason.CredentialsRejected, "station.join-rejected", message, core)
            error is StationJoin.Failure.HotspotUnavailable -> failure(ConnectionFailure.Reason.JoinFailed, "station.hotspot-unavailable", message, core)
            error is StationJoin.Failure.UnsupportedRole || error is StationJoin.Failure.RoleRefused ->
                failure(ConnectionFailure.Reason.Unsupported, "station.role-refused", message, core)
            error is StationJoin.Failure -> failure(ConnectionFailure.Reason.TimedOut, "station.silent", message, core)
            error is SecurityException -> failure(
                ConnectionFailure.Reason.Permission(ConnectionFailure.Permission.NEARBY_DEVICES), "bluetooth.denied", message, core,
            ).copy(actions = listOf(RecoveryAction.OpenSettings, RecoveryAction.Retry))
            phase == ConnectionPhase.AWAITING_APPROVAL || "pairing timed out" in lower ->
                failure(ConnectionFailure.Reason.NotApproved, "approval.timeout", message, CorePhase.AWAITING_APPROVAL)
            "password is missing" in lower -> failure(ConnectionFailure.Reason.CredentialsRejected, "station.password-missing", message, core)
            phase == ConnectionPhase.JOINING_WIFI -> failure(ConnectionFailure.Reason.JoinFailed, "wifi.join-failed", message, core)
            error is TimeoutCancellationException || "timed out" in lower -> failure(ConnectionFailure.Reason.TimedOut, "timeout", message, core)
            "disappeared" in lower || "disconnected" in lower -> failure(ConnectionFailure.Reason.LinkLost, "link.lost", message, core)
            else -> failure(ConnectionFailure.Reason.Other, "connect.failed", message, core)
        }
    }

    fun linkLost(message: String) = failure(ConnectionFailure.Reason.LinkLost, "link.lost", message, CorePhase.LINK)

    /** The session's phase as the core phase (the mapping the iOS control port uses). */
    fun corePhase(phase: ConnectionPhase): CorePhase? = when (phase) {
        ConnectionPhase.SCANNING, ConnectionPhase.CONNECTING_GATT, ConnectionPhase.PAIRING, ConnectionPhase.READING_WIFI_CREDS -> CorePhase.LINK
        ConnectionPhase.AWAITING_APPROVAL -> CorePhase.AWAITING_APPROVAL
        ConnectionPhase.JOINING_WIFI -> CorePhase.JOINING_NETWORK
        ConnectionPhase.OPENING_DATALINK -> CorePhase.NEGOTIATING
        ConnectionPhase.IDLE, ConnectionPhase.LIVE, ConnectionPhase.FAILED -> null
    }
}

/**
 * The DJI [CameraIntegration] (Swift `DJIIntegration`): passive Bluetooth discovery, one
 * connection at a time over camera Wi-Fi or a saved Wi-Fi or hotspot setup (the camera moves to
 * that network), the connect card's steps, approval and network-join prompts, typed failures
 * with the session's copy and route actions, and forget of the camera's saved Wi-Fi. Network
 * passwords and camera credentials live in the stores the app passes. Collect on the main thread.
 */
class DjiIntegration(
    private val port: DjiConnectPort,
    private val loadNetwork: (ssid: String, hotspot: Boolean) -> MultiviewNetworkStore.Network? = { _, _ -> null },
    private val saveNetwork: (ssid: String, password: String, hotspot: Boolean) -> Unit = { _, _, _ -> },
    private val forgetCredentials: (cameraId: String) -> Unit = {},
    private val now: () -> Long = System::currentTimeMillis,
) : CameraIntegration {
    override val id = DjiCameraSessionAdapter.INTEGRATION

    /** The verified bodies (Swift `CameraModel.byId`). Bodies that list in Multiview add Wi-Fi and hotspot setups. */
    override val profiles: List<CameraProfile> = listOf(
        "Osmo Action 5 Pro", "Osmo Action 6", "Osmo Nano", "Osmo Pocket 3", "Osmo Pocket 4", "Osmo Pocket 4 Pro",
    ).map { CameraProfile("${id.rawValue}.model.${it.lowercase().replace(' ', '-')}", it, ALL_ROUTES, MOVING_ROUTES) }

    override val discoveryModes: Set<DiscoveryMode> = setOf(DiscoveryMode.PASSIVE)
    private var listening = 0
    /** The attempt that owns the session; an older collection ends when a newer one takes it. */
    private var current: ConnectionAttemptID? = null

    companion object {
        val ALL_ROUTES = setOf(RouteKind.CAMERA_ACCESS_POINT, RouteKind.INFRASTRUCTURE_NETWORK, RouteKind.PHONE_HOTSPOT)
        val MOVING_ROUTES = setOf(RouteKind.INFRASTRUCTURE_NETWORK, RouteKind.PHONE_HOTSPOT)
        const val APPROVE = "Approve on the camera"
        const val LOOKING = "Looking for the camera"

        /** The connect card's plan: camera Wi-Fi, or moving the camera to a Wi-Fi or hotspot setup. */
        fun steps(route: SavedRoute?): List<ConnectionStep> {
            val moving = route != null && route.kind != RouteKind.CAMERA_ACCESS_POINT
            val network = route?.network ?: if (route?.kind == RouteKind.PHONE_HOTSPOT) "Hotspot" else "Wi-Fi"
            return listOf(
                ConnectionStep("Connecting over Bluetooth"),
                ConnectionStep(if (moving) "Moving the camera to $network" else "Joining camera Wi-Fi"),
                ConnectionStep(if (moving) "Finding the camera" else "Opening the video link"),
                ConnectionStep("Starting the picture"),
            )
        }

        fun setup(kind: RouteKind): CameraConnectionSetup = when (kind) {
            RouteKind.INFRASTRUCTURE_NETWORK -> CameraConnectionSetup.WIFI
            RouteKind.PHONE_HOTSPOT -> CameraConnectionSetup.PHONE_HOTSPOT
            else -> CameraConnectionSetup.CAMERA_WIFI
        }
    }

    override fun discover(mode: DiscoveryMode): Flow<List<NearbyCamera>> {
        if (mode !in discoveryModes) return emptyFlow()
        return flow {
            if (listening++ == 0) port.startScan()
            try {
                emitAll(port.found.map { cameras -> cameras.map(::sighting) })
            } finally {
                if (--listening == 0) port.stopScan()
            }
        }
    }

    private fun sighting(camera: FoundCamera) = NearbyCamera(
        camera.id, name = FoundCameraIdentity.listTitle(camera.name, camera.model.name), model = camera.model.name,
        routes = setOf(RouteKind.CAMERA_ACCESS_POINT),
    )

    override fun connect(target: ConnectTarget): Flow<ConnectionEvent> = channelFlow {
        val (cameraID, route, camera) = when (target) {
            is ConnectTarget.Saved -> Triple(target.camera.id, target.camera.routes.firstOrNull { it.id == target.route }, target.camera)
            is ConnectTarget.Nearby -> Triple(target.camera.id, null, null)
            is ConnectTarget.AddRoute -> {
                val draft = target.draft
                val network = draft.network
                if (draft.kind !in MOVING_ROUTES || network == null) {
                    send(ConnectionEvent.Failed(DjiFailures.classify(null, ConnectionPhase.IDLE, "This setup cannot be added.").copy(reason = ConnectionFailure.Reason.Unsupported)))
                    return@channelFlow
                }
                draft.secret?.let { saveNetwork(network, it, draft.kind == RouteKind.PHONE_HOTSPOT) }
                val added = SavedRoute(key = if (draft.kind == RouteKind.PHONE_HOTSPOT) "hotspot" else "wifi", kind = draft.kind, title = draft.title, network = network, bluetooth = true)
                Triple(target.camera.id, added, target.camera.copy(routes = target.camera.routes.filter { it.key != added.key } + added))
            }
        }
        val setup = route?.let { setup(it.kind) } ?: CameraConnectionSetup.CAMERA_WIFI
        val network = route?.network?.takeIf { setup.movesCamera }?.let { loadNetwork(it, setup == CameraConnectionSetup.PHONE_HOTSPOT) }
        val attempt = ConnectionAttemptID()
        val steps = steps(route)
        current = attempt
        // One session, one connection: end whatever runs, then connect with this setup.
        if (port.phaseFlow.value !in setOf(ConnectionPhase.IDLE, ConnectionPhase.SCANNING, ConnectionPhase.FAILED)) port.disconnect()
        port.useSetup(setup, network, restoreAccessPoint = camera?.let(::mayBeInStationRole) == true)
        port.reconnect(cameraID)
        var last: ConnectionEvent.Progress? = null
        var outcome: ConnectionEvent? = null
        try {
            port.phaseFlow.first { phase ->
                // ponytail: a replaced attempt ends at the session's next phase, not at once; a
                // shared StateFlow of the owner would end it at once if a card ever lingers.
                if (current != attempt) return@first true
                when (phase) {
                    ConnectionPhase.LIVE -> outcome = ConnectionEvent.Connected(ConnectedCamera(record(target, camera, route), port.control))
                    ConnectionPhase.FAILED -> port.failureDetail.value?.let { outcome = ConnectionEvent.Failed(withRouteActions(it, camera, route)) }
                    ConnectionPhase.IDLE -> return@first true
                    else -> {
                        val progress = progress(attempt, phase, steps, route)
                        if (progress != null && progress != last) {
                            last = progress
                            send(progress)
                        }
                    }
                }
                outcome != null
            }
            outcome?.let { send(it) }
        } finally {
            // The consumer stopped listening before an outcome: cancel the attempt.
            if (outcome == null && current == attempt && port.phaseFlow.value != ConnectionPhase.IDLE) port.disconnect()
        }
    }

    override suspend fun forget(camera: SavedCamera) {
        forgetCredentials(camera.id)
    }

    private fun progress(attempt: ConnectionAttemptID, phase: ConnectionPhase, steps: List<ConnectionStep>, route: SavedRoute?): ConnectionEvent.Progress? {
        val corePhase = DjiFailures.corePhase(phase) ?: return null
        val finding = port.setupProgress.value?.startsWith("Finding") == true
        val step = when (phase) {
            ConnectionPhase.READING_WIFI_CREDS, ConnectionPhase.JOINING_WIFI -> if (finding) 2 else 1
            ConnectionPhase.OPENING_DATALINK -> 2
            else -> 0
        }
        val prompt = when (phase) {
            ConnectionPhase.AWAITING_APPROVAL -> ConnectionPrompt.ApproveOnCamera(APPROVE)
            else -> null
        }
        val note = when {
            phase == ConnectionPhase.SCANNING -> LOOKING
            step == 1 -> port.setupProgress.value
            else -> null
        }
        return ConnectionEvent.Progress(ConnectionProgress(attempt, corePhase, steps, step, note), prompt)
    }

    /** A setup that moves the camera may have left it in station role (iOS `lastSetup`). */
    private fun mayBeInStationRole(camera: SavedCamera): Boolean {
        val preferred = camera.routes.firstOrNull { it.id == camera.preferredRoute }
        return preferred?.kind in MOVING_ROUTES || camera.extras["lastSetup"] in setOf("wifi", "phoneHotspot")
    }

    /** Route actions: edit the setup that failed, or fall back to the camera's own Wi-Fi. */
    private fun withRouteActions(failure: ConnectionFailure, camera: SavedCamera?, route: SavedRoute?): ConnectionFailure {
        if (route == null || route.kind !in MOVING_ROUTES) return failure
        val ap = camera?.routes?.firstOrNull { it.kind == RouteKind.CAMERA_ACCESS_POINT }
        val title = "Couldn’t connect over ${route.title ?: route.network ?: if (route.kind == RouteKind.PHONE_HOTSPOT) "Hotspot" else "Wi-Fi"}"
        val actions = failure.actions.filter { it != RecoveryAction.Retry } + RecoveryAction.EditRoute(route.id) + RecoveryAction.Retry +
            listOfNotNull(ap?.let { RecoveryAction.UseRoute(it.id) })
        return failure.copy(title = title, actions = actions)
    }

    /** The saved record after a connect: the route it used as preferred, the joined camera network. */
    private fun record(target: ConnectTarget, camera: SavedCamera?, route: SavedRoute?): SavedCamera {
        val base = camera ?: (target as ConnectTarget.Nearby).let {
            SavedCamera(id = it.camera.savedID ?: it.camera.id, integration = id, advertisedName = it.camera.name, model = it.camera.model)
        }
        val joined = port.joinedSSID
        var routes = base.routes
        if (routes.none { it.kind == RouteKind.CAMERA_ACCESS_POINT }) {
            routes = listOf(SavedRoute(key = "ap", kind = RouteKind.CAMERA_ACCESS_POINT, bluetooth = true)) + routes
        }
        if (route == null || route.kind == RouteKind.CAMERA_ACCESS_POINT) {
            routes = routes.map { if (it.kind == RouteKind.CAMERA_ACCESS_POINT && joined != null) it.copy(network = joined) else it }
        }
        val used = routes.firstOrNull { it.key == (route?.key ?: "ap") } ?: routes.first()
        // iOS save rule (D9): the advertised model id is kept with the record.
        val modelId = port.found.value.firstOrNull { it.id == base.id }?.modelId
        val extras = modelId?.let { base.extras + ("modelId" to it.toString()) } ?: base.extras
        return base.copy(routes = routes, preferredRoute = used.id, lastConnected = now(), extras = extras)
    }
}
