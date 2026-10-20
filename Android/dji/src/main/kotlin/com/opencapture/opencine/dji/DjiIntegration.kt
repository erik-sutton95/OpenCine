package com.opencapture.opencine.dji

import com.opencapture.opencine.core.CameraIntegration
import com.opencapture.opencine.core.CameraProfile
import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.CameraServices
import com.opencapture.opencine.core.ConnectTarget
import com.opencapture.opencine.core.ConnectedCamera
import com.opencapture.opencine.core.ConnectionAttemptID
import com.opencapture.opencine.core.ConnectionEvent
import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.ConnectionProgress
import com.opencapture.opencine.core.ConnectionPrompt
import com.opencapture.opencine.core.ConnectionStep
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.core.DiscoveryMode
import com.opencapture.opencine.core.IntegrationPresentation
import com.opencapture.opencine.core.NearbyCamera
import com.opencapture.opencine.core.RecoveryAction
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.core.SavedRoute
import com.opencapture.opencine.vocabulary.ConnectionPhase
import com.opencapture.opencine.vocabulary.FoundCamera
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import com.opencapture.opencine.core.ConnectionPhase as CorePhase

/** The common session identity exposed through DJI's downward integration boundary. */
public typealias DJICameraSessionID = CameraSessionID

/** The common control epoch exposed through DJI's downward integration boundary. */
public typealias DJIControlEpoch = ControlEpoch

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
    /** Actual source-owned optional services; older ports keep no advertised defaults. */
    val services: CameraServices get() = CameraServices()
    fun startScan()
    fun stopScan()
    fun useSetup(setup: CameraConnectionSetup, network: MultiviewNetworkStore.Network?, restoreAccessPoint: Boolean)
    /** Connects the camera now when it is nearby, else scans for it and connects when it appears. */
    fun reconnect(id: String)
    fun disconnect()
}

/** DJI connection failures with the session's own copy (Swift: the app's typed errors). */
object DjiFailures {
    /** Frame Tap or a running DJI Mimo holds the camera and blocks pairing and the video link. */
    const val DJI_APPS_TIP = "Turn off DJI Frame Tap and force quit DJI Mimo on every phone near the camera."
    const val HOTSPOT_OFF = "The camera could not find this phone’s hotspot. Turn on the Wi-Fi hotspot, then try again."

    private fun failure(reason: ConnectionFailure.Reason, code: String, message: String, phase: CorePhase?) =
        ConnectionFailure(
            reason, phase, "Couldn’t connect over Camera Wi-Fi", message, listOf(RecoveryAction.Retry),
            "${DjiCameraSessionAdapter.INTEGRATION.rawValue}.$code",
        )

    /**
     * The card and pair page copy for the session's reason [raw]: the baseline
     * `StartupConnectionCopy.friendly` sentence (never the raw technical text), with the DJI apps
     * tip when the camera never answered pairing or the video link (PAB-C-23).
     */
    fun copy(raw: String): String {
        val trimmed = raw.trim()
        val lower = trimmed.lowercase()
        val tip = "pairing timed out" in lower || "never answered the datalink handshake" in lower
        val sentence =
            when {
                "never answered the datalink handshake" in lower -> "The camera never answered the video link."
                "timed out" in lower || "timeout" in lower ->
                    "The camera didn't respond in time. Check Bluetooth and try again."
                "disconnected" in lower -> "The camera ended the connection. Try again."
                else -> trimmed.replaceFirstChar { it.uppercase() }.let { if (it.endsWith(".")) it else "$it." }
            }
        return if (tip) "$sentence $DJI_APPS_TIP" else sentence
    }

    /**
     * A connect that threw [error] in [phase]; [message] is the session's reason, shown as
     * [copy]. [hotspotOff]: a hotspot setup failed while this phone's hotspot was down.
     */
    fun classify(error: Throwable?, phase: ConnectionPhase, message: String, hotspotOff: Boolean = false): ConnectionFailure =
        typed(error, phase, message).copy(message = if (hotspotOff) HOTSPOT_OFF else copy(message))

    private fun typed(error: Throwable?, phase: ConnectionPhase, message: String): ConnectionFailure {
        val core = corePhase(phase)
        val lower = message.lowercase()
        return when {
            error is DatalinkHandshakeException -> failure(ConnectionFailure.Reason.TimedOut, "datalink.silent", message, core)
            error is StationJoin.Failure.JoinRejected -> failure(ConnectionFailure.Reason.CredentialsRejected, "station.join-rejected", message, core)
            error is StationJoin.Failure.HotspotUnavailable -> failure(ConnectionFailure.Reason.JoinFailed, "station.hotspot-unavailable", message, core)
            error is StationJoin.Failure.UnsupportedRole || error is StationJoin.Failure.RoleRefused ->
                failure(ConnectionFailure.Reason.Unsupported, "station.role-refused", message, core)
            error is StationJoin.Failure -> failure(ConnectionFailure.Reason.TimedOut, "station.silent", message, core)
            // Try again only, as the Android cards have always offered: the pair page's
            // Nearby devices action is the way to the permission.
            error is SecurityException -> failure(
                ConnectionFailure.Reason.Permission(ConnectionFailure.Permission.NEARBY_DEVICES), "bluetooth.denied", message, core,
            )
            phase == ConnectionPhase.AWAITING_APPROVAL || "pairing timed out" in lower ->
                failure(ConnectionFailure.Reason.NotApproved, "approval.timeout", message, CorePhase.AWAITING_APPROVAL)
            "password is missing" in lower -> failure(ConnectionFailure.Reason.CredentialsRejected, "station.password-missing", message, core)
            phase == ConnectionPhase.JOINING_WIFI -> failure(ConnectionFailure.Reason.JoinFailed, "wifi.join-failed", message, core)
            error is TimeoutCancellationException || "timed out" in lower -> failure(ConnectionFailure.Reason.TimedOut, "timeout", message, core)
            "disappeared" in lower || "disconnected" in lower -> failure(ConnectionFailure.Reason.LinkLost, "link.lost", message, core)
            else -> failure(ConnectionFailure.Reason.Other, "connect.failed", message, core)
        }
    }

    fun linkLost(message: String) = failure(ConnectionFailure.Reason.LinkLost, "link.lost", copy(message), CorePhase.LINK)

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
    private val forgetCredentialsAsync: (suspend (cameraId: String) -> Unit)?,
    private val loadNetwork: (ssid: String, hotspot: Boolean) -> MultiviewNetworkStore.Network? = { _, _ -> null },
    private val saveNetwork: (ssid: String, password: String, hotspot: Boolean) -> Unit = { _, _, _ -> },
    private val forgetCredentials: (cameraId: String) -> Unit = {},
    private val now: () -> Long = System::currentTimeMillis,
) : CameraIntegration {
    /** Original constructor, including its JVM/default signature and trailing clock lambda. */
    constructor(
        port: DjiConnectPort,
        loadNetwork: (ssid: String, hotspot: Boolean) -> MultiviewNetworkStore.Network? = { _, _ -> null },
        saveNetwork: (ssid: String, password: String, hotspot: Boolean) -> Unit = { _, _, _ -> },
        forgetCredentials: (cameraId: String) -> Unit = {},
        now: () -> Long = System::currentTimeMillis,
    ) : this(port, null, loadNetwork, saveNetwork, forgetCredentials, now)

    override val id = DjiCameraSessionAdapter.INTEGRATION

    /** The verified bodies (Swift `CameraModel.byId`). Bodies that list in Multiview add Wi-Fi and hotspot setups. */
    override val profiles: List<CameraProfile> = listOf(
        "Osmo Action 5 Pro", "Osmo Action 6", "Osmo Nano", "Osmo Pocket 3", "Osmo Pocket 4", "Osmo Pocket 4 Pro",
    ).map { CameraProfile("${id.rawValue}.model.${it.lowercase().replace(' ', '-')}", it, ALL_ROUTES, MOVING_ROUTES) }

    override val discoveryModes: Set<DiscoveryMode> = setOf(DiscoveryMode.PASSIVE)

    /** A nearby card pairs at once (the camera approves it); setups keep their kind's name. */
    override val presentation: IntegrationPresentation =
        IntegrationPresentation(nearbyTap = IntegrationPresentation.NearbyTap.CONNECT, namesSetups = false)

    /**
     * The app's saved cameras. A camera network another saved camera owns (its access point or
     * advertised name), or one of another body family, is never saved with this camera.
     */
    var savedCameras: () -> List<SavedCamera> = { emptyList() }

    /**
     * Stores a record before an attempt starts: a setup that moves the camera is remembered (with
     * a route being added) before it can move the camera, so a later camera Wi-Fi connect
     * restores the access point even when this attempt fails. The app upserts it.
     */
    var saveRecord: (SavedCamera) -> Unit = {}
    private var listening = 0
    /** The attempt that owns the session; an older collection ends when a newer one takes it. */
    private var current: ConnectionAttemptID? = null

    companion object {
        val ALL_ROUTES = setOf(RouteKind.CAMERA_ACCESS_POINT, RouteKind.INFRASTRUCTURE_NETWORK, RouteKind.PHONE_HOTSPOT)
        val MOVING_ROUTES = setOf(RouteKind.INFRASTRUCTURE_NETWORK, RouteKind.PHONE_HOTSPOT)
        const val APPROVE = "Approve on the camera"
        const val LOOKING = "Looking for the camera"
        /** The Wi-Fi step's caption while the session reports no setup progress (the apps' phase labels). */
        const val READING = "Reading Wi-Fi credentials…"
        const val JOINING = "Joining camera Wi-Fi…"

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

        /**
         * [camera] remembering that a setup of [kind] may move it to station role: that route
         * becomes preferred, or without one the legacy `lastSetup` stays in `extras`. Camera
         * Wi-Fi is stamped only once live, so a failed restore is retried on the next connect.
         */
        fun stamping(camera: SavedCamera, kind: RouteKind): SavedCamera {
            if (kind !in MOVING_ROUTES) return camera
            val route = camera.routes.firstOrNull { it.kind == kind }
            return if (route != null) {
                camera.copy(preferredRoute = route.id, extras = camera.extras - "lastSetup")
            } else {
                camera.copy(preferredRoute = null, extras = camera.extras + ("lastSetup" to if (kind == RouteKind.PHONE_HOTSPOT) "phoneHotspot" else "wifi"))
            }
        }

        /** The iOS save rule (D9): a network another saved camera owns, or of another body family. */
        fun ownedElsewhere(network: String, camera: SavedCamera, saved: List<SavedCamera>): Boolean {
            val needle = network.trim().lowercase()
            fun same(value: String?) = value?.trim()?.lowercase() == needle
            val other = saved.any { other ->
                other.id != camera.id &&
                    (same(other.advertisedName) || other.routes.any { it.kind == RouteKind.CAMERA_ACCESS_POINT && same(it.network) })
            }
            val body = family(camera.extras["modelId"]?.toIntOrNull(), camera.advertisedName)
            val wifi = family(null, network)
            return other || (body != null && wifi != null && body != wifi)
        }

        /** Swift `CameraBodyFamily.resolve`: `pocket`, `nano`, or `null` for other bodies. */
        private fun family(modelId: Int?, name: String?): String? {
            when (modelId) {
                0x20, 0x21, 0x22 -> return "pocket"
                0x19 -> return "nano"
            }
            val n = name.orEmpty().lowercase().replace(" ", "")
            return when {
                "pocket" in n || "muse" in n -> "pocket"
                "nano" in n || "atto" in n -> "nano"
                else -> null
            }
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
            is ConnectTarget.Saved -> Triple(target.camera.id, target.camera.routes.firstOrNull { it.id == target.route }, target.camera).also { (_, route, camera) ->
                if (route != null && route.kind in MOVING_ROUTES) saveRecord(stamping(camera, route.kind))
            }
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
                    .also { saveRecord(stamping(it.third, added.kind)) }
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
            // The setup's live text can change within one phase (the station search starts while
            // JOINING_WIFI holds), so the card follows both.
            combine(port.phaseFlow, port.setupProgress) { phase, _ -> phase }.first { phase ->
                // ponytail: a replaced attempt ends at the session's next phase, not at once; a
                // shared StateFlow of the owner would end it at once if a card ever lingers.
                if (current != attempt) return@first true
                when (phase) {
                    ConnectionPhase.LIVE -> outcome = ConnectionEvent.Connected(ConnectedCamera(record(target, camera, route), port.control, port.services))
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
        val async = forgetCredentialsAsync
        if (async != null) async(camera.id) else forgetCredentials(camera.id)
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
            // The setup's live text ("Finding the camera on <network>") is the caption on every
            // step it reaches, not only the first (PAB-C-36).
            step != 0 -> port.setupProgress.value ?: if (step == 1) {
                if (phase == ConnectionPhase.READING_WIFI_CREDS) READING else JOINING
            } else {
                null
            }
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

    /**
     * The saved record after a connect: the route it used as preferred, the joined camera network
     * unless another camera owns it, the advertised name and model id (iOS save rules, D9).
     */
    private fun record(target: ConnectTarget, camera: SavedCamera?, route: SavedRoute?): SavedCamera {
        val start = camera ?: (target as ConnectTarget.Nearby).let {
            SavedCamera(id = it.camera.savedID ?: it.camera.id, integration = id, advertisedName = it.camera.name, model = it.camera.model)
        }
        val sighting = port.found.value.firstOrNull { it.id == start.id }
        // The connect leaves the camera in the role of the route it used.
        var extras = start.extras - "lastSetup"
        sighting?.modelId?.let { extras = extras + ("modelId" to it.toString()) }
        val base = start.copy(
            advertisedName = sighting?.name?.takeUnless(FoundCameraIdentity::isGenericName) ?: start.advertisedName,
            extras = extras,
        )
        val joined = port.joinedSSID?.takeUnless { ownedElsewhere(it, base, savedCameras()) }
        var routes = base.routes
        if (routes.none { it.kind == RouteKind.CAMERA_ACCESS_POINT }) {
            routes = listOf(SavedRoute(key = "ap", kind = RouteKind.CAMERA_ACCESS_POINT, bluetooth = true)) + routes
        }
        if (route == null || route.kind == RouteKind.CAMERA_ACCESS_POINT) {
            routes = routes.map { if (it.kind == RouteKind.CAMERA_ACCESS_POINT && joined != null) it.copy(network = joined) else it }
        }
        val used = routes.firstOrNull { it.key == (route?.key ?: "ap") } ?: routes.first()
        return base.copy(routes = routes, preferredRoute = used.id, lastConnected = now())
    }
}
