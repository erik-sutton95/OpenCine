package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.CameraIntegration
import com.opencapture.opencine.core.CameraProfile
import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.ConnectTarget
import com.opencapture.opencine.core.ConnectedCamera
import com.opencapture.opencine.core.CameraServices
import com.opencapture.opencine.media.CameraMediaService
import com.opencapture.opencine.insta360.shell.CameraMediaServiceSource
import com.opencapture.opencine.core.ConnectionAttemptID
import com.opencapture.opencine.core.ConnectionEvent
import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.ConnectionPhase as CorePhase
import com.opencapture.opencine.core.ConnectionProgress
import com.opencapture.opencine.core.ConnectionPrompt
import com.opencapture.opencine.core.ConnectionStep
import com.opencapture.opencine.core.DiscoveryMode
import com.opencapture.opencine.core.IntegrationPresentation
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.NearbyCamera
import com.opencapture.opencine.core.RecoveryAction
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.core.SavedRoute
import com.opencapture.opencine.insta360.shell.CameraIdentity
import com.opencapture.opencine.insta360.shell.ConnectionPhase
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * What [LunaIntegration] needs from the Luna backend (Swift `LunaConnectPort`): discovery, one
 * connection, its session, and forgetting a camera's saved Wi-Fi. [LunaBackend] is the one
 * implementation; tests script a fake.
 */
interface LunaConnectPort : CameraMediaServiceSource {
    val phase: StateFlow<ConnectionPhase>
    val found: StateFlow<List<CameraIdentity>>
    val joinedSSID: StateFlow<String?>
    /** Why the last attempt failed, typed; `null` while none has. */
    val failureDetail: StateFlow<ConnectionFailure?>
    /** `true` while discovery cannot run: radio off, permission denied or the scanner refused. */
    val scanBlocked: StateFlow<Boolean>
    /** The connection job [connect] started; it keeps running while the camera is live. */
    val attempt: Job?
    fun startScan()
    fun stopScan()
    /** Whether this run has heard the camera advertise, so Bluetooth can reach it now. */
    fun hasSeen(id: String): Boolean
    /** Whether saved camera Wi-Fi exists for a camera that is not advertising. */
    suspend fun hasSavedWiFi(id: String): Boolean
    fun connect(id: String)
    fun disconnect()
    /** A new core session for the next connection; the previous one closes as replaced. */
    fun openSession(): CameraSession
    /** Drops the camera's saved Wi-Fi off Main. The approval identity stays. */
    suspend fun forget(id: String)
}

/** The Luna failures with the copy the backend has always shown (Swift `ConnectionFailure.luna`). */
object LunaFailures {
    val INTEGRATION: IntegrationID = LunaCameraSession.INTEGRATION

    fun failure(
        reason: ConnectionFailure.Reason,
        code: String,
        message: String,
        phase: CorePhase? = null,
        actions: List<RecoveryAction> = listOf(RecoveryAction.Retry),
    ) = ConnectionFailure(reason, phase, "Couldn’t connect over Camera Wi-Fi", message, actions, "${INTEGRATION.rawValue}.$code")

    /**
     * A connect that failed in [phase]: the operator copy is chosen by the phase it failed in.
     * [advertising] is false when this run has not heard the camera, so it is off or out of range.
     */
    fun connect(phase: ConnectionPhase, advertising: Boolean = true): ConnectionFailure = when {
        phase == ConnectionPhase.CONNECTING_GATT && !advertising -> cameraMissing
        else -> byPhase(phase)
    }

    /** The camera did not answer and this run never heard it: it is off or out of range. */
    val cameraMissing = failure(
        ConnectionFailure.Reason.NotFound, "bluetooth.camera-missing",
        "The camera did not answer. Make sure it is turned on and nearby, then try again.", CorePhase.LINK,
    )

    private fun byPhase(phase: ConnectionPhase): ConnectionFailure = when (phase) {
        ConnectionPhase.AWAITING_APPROVAL -> failure(
            ConnectionFailure.Reason.NotApproved, "approval.incomplete",
            "Camera approval was not completed. Wake Luna and accept the connection on its screen.", CorePhase.AWAITING_APPROVAL,
        )
        ConnectionPhase.JOINING_WIFI -> failure(
            ConnectionFailure.Reason.JoinFailed, "wifi.join-failed",
            "Could not join Luna Wi-Fi. Keep the camera awake and accept Android's Wi-Fi connection request.", CorePhase.JOINING_NETWORK,
        )
        ConnectionPhase.LIVE -> failure(
            ConnectionFailure.Reason.LinkLost, "link.dropped", "The camera feed disconnected. Wake Luna and tap Retry.", CorePhase.LINK,
        )
        ConnectionPhase.OPENING_DATALINK -> failure(
            ConnectionFailure.Reason.Other, "video.not-started",
            "The camera Wi-Fi connected, but live view did not start. Close the Insta360 app and try again.", CorePhase.LINK,
        )
        else -> failure(
            ConnectionFailure.Reason.Other, "connect.failed",
            "Could not connect to Luna. Keep it awake, close the Insta360 app, and try again.", corePhase(phase),
        )
    }

    fun scanFailed(code: Int) = failure(
        ConnectionFailure.Reason.Permission(ConnectionFailure.Permission.NEARBY_DEVICES), "bluetooth.scan-failed",
        "Bluetooth scanning could not start ($code). Check Nearby devices permission.",
        actions = listOf(RecoveryAction.OpenSettings, RecoveryAction.Retry),
    )

    val discoveryDenied = failure(
        ConnectionFailure.Reason.Permission(ConnectionFailure.Permission.NEARBY_DEVICES), "bluetooth.denied",
        "Allow Nearby devices and location access to discover your camera.",
        actions = listOf(RecoveryAction.OpenSettings, RecoveryAction.Retry),
    )

    /** The backend's link phase as the core phase (the same mapping [LunaCameraSession] reports). */
    fun corePhase(phase: ConnectionPhase): CorePhase? = when (phase) {
        ConnectionPhase.CONNECTING_GATT, ConnectionPhase.PAIRING -> CorePhase.NEGOTIATING
        ConnectionPhase.AWAITING_APPROVAL -> CorePhase.AWAITING_APPROVAL
        ConnectionPhase.READING_WIFI_CREDS, ConnectionPhase.JOINING_WIFI -> CorePhase.JOINING_NETWORK
        ConnectionPhase.SCANNING, ConnectionPhase.OPENING_DATALINK, ConnectionPhase.LIVE -> CorePhase.LINK
        ConnectionPhase.IDLE, ConnectionPhase.FAILED -> null
    }
}

/**
 * The Luna [CameraIntegration] (Swift `LunaIntegration`): passive Bluetooth discovery, one
 * connection at a time over the backend's Bluetooth bootstrap or saved Wi-Fi, approval and
 * network-join prompts, typed failures with the backend's copy, and forget. Collect on the main
 * thread, like the backend.
 */
class LunaIntegration(
    private val port: LunaConnectPort,
    private val now: () -> Long = System::currentTimeMillis,
    /** The grace loop's pause; tests run it on their virtual clock. */
    private val sleep: suspend (Long) -> Unit = { delay(it) },
) : CameraIntegration {
    override val id: IntegrationID = LunaCameraSession.INTEGRATION
    override val profiles: List<CameraProfile> =
        listOf(CameraProfile("${id.rawValue}.luna-ultra", "Luna Ultra", setOf(RouteKind.CAMERA_ACCESS_POINT)))
    override val discoveryModes: Set<DiscoveryMode> = setOf(DiscoveryMode.PASSIVE)

    /** A nearby card pairs at once (the camera approves it); setups keep their kind's name. */
    override val presentation: IntegrationPresentation =
        IntegrationPresentation(nearbyTap = IntegrationPresentation.NearbyTap.CONNECT, namesSetups = false)

    private var listening = 0

    companion object {
        /** The connect card's plan, in the order the backend runs it. */
        val STEPS = listOf(
            ConnectionStep("Connecting over Bluetooth"), ConnectionStep("Joining camera Wi-Fi"),
            ConnectionStep("Opening the video link"), ConnectionStep("Starting the picture"),
        )
        const val APPROVE = "Approve on the camera"
        /** How long a saved connection gives Bluetooth to hear the camera before saved Wi-Fi. */
        const val SIGHTING_GRACE_MS = 4_000L
        const val SIGHTING_STEP_MS = 100L
    }

    override fun discover(mode: DiscoveryMode): Flow<List<NearbyCamera>> {
        if (mode !in discoveryModes) return emptyFlow()
        return flow {
            if (listening++ == 0) port.startScan()
            try {
                emitAll(port.found.map { cameras -> cameras.map { NearbyCamera(it.id, name = it.advertisedName, model = it.modelName, routes = setOf(RouteKind.CAMERA_ACCESS_POINT)) } })
            } finally {
                if (--listening == 0) port.stopScan()
            }
        }
    }

    /**
     * Discovery runs unless the scan itself is blocked (Bluetooth off, permission denied, scanner
     * refused), so the pages show no scanning status then; a failed connect leaves it running
     * (IA-336, Swift `discoveryFailure`).
     */
    override val discoveryRunning: Flow<Boolean> = port.scanBlocked.map { !it }.distinctUntilChanged()

    override fun connect(target: ConnectTarget): Flow<ConnectionEvent> = channelFlow {
        val cameraID = when (target) {
            is ConnectTarget.Saved -> target.camera.id
            is ConnectTarget.Nearby -> target.camera.id
            is ConnectTarget.AddRoute -> null
        }
        if (cameraID == null) {
            send(ConnectionEvent.Failed(LunaFailures.failure(ConnectionFailure.Reason.Unsupported, "route.unsupported", "This camera connects over its own Wi-Fi only.")))
            return@channelFlow
        }
        val attempt = ConnectionAttemptID()
        val session = port.openSession()
        // The baseline grace, before a newer attempt retires the old one: a saved camera that has
        // not advertised yet gets Bluetooth first, because an advert proves it is awake and waking
        // its Wi-Fi is quicker than dialling a sleeping access point.
        if (target is ConnectTarget.Saved && port.hasSavedWiFi(cameraID) && !port.hasSeen(cameraID)) {
            progress(attempt, ConnectionPhase.SCANNING)?.let { send(it) }
            // A radio that cannot scan still has the saved Wi-Fi route (the baseline did the same).
            // The grace holds the scan like a listener, so a discovery page closing meanwhile
            // cannot stop it; a cancelled grace stops the scan unless a listener still wants it.
            listening++
            runCatching { port.startScan() }
            var waited = false
            try {
                val deadline = now() + SIGHTING_GRACE_MS
                while (!port.hasSeen(cameraID) && now() < deadline) {
                    sleep(SIGHTING_STEP_MS)
                }
                waited = true
            } finally {
                if (--listening == 0 && !waited) port.stopScan()
            }
        }
        // One backend, one connection: a newer attempt ends the older one (its job is cancelled).
        port.disconnect()
        port.connect(cameraID)
        val job = port.attempt
        val outcome = CompletableDeferred<ConnectionEvent?>()
        var last: ConnectionEvent.Progress? = null
        val watcher = launch {
            port.phase.collect { phase ->
                if (phase == ConnectionPhase.LIVE && job?.isActive == true) {
                    val media = port.mediaService(session.id)?.takeIf { it.sessionID == session.id }
                    val services = media?.let { CameraServices().plus(CameraMediaService::class, it) }
                        ?: CameraServices()
                    outcome.complete(ConnectionEvent.Connected(ConnectedCamera(record(target), session, services)))
                    return@collect
                }
                val progress = progress(attempt, phase) ?: return@collect
                if (progress != last) {
                    last = progress
                    send(progress)
                }
            }
        }
        val ender = launch {
            job?.join()
            outcome.complete(
                if (job == null || job.isCancelled) null else ConnectionEvent.Failed(port.failureDetail.value ?: LunaFailures.connect(port.phase.value)),
            )
        }
        try {
            outcome.await()?.let { send(it) }
        } finally {
            watcher.cancel()
            ender.cancel()
            // The consumer stopped listening before an outcome: cancel the attempt.
            if (!outcome.isCompleted) port.disconnect()
        }
    }

    override suspend fun forget(camera: SavedCamera) {
        port.forget(camera.id)
    }

    /** The connect card's step, prompt and note for a backend phase; `null` for idle and failed. */
    private fun progress(attempt: ConnectionAttemptID, phase: ConnectionPhase): ConnectionEvent.Progress? {
        val corePhase = LunaFailures.corePhase(phase) ?: return null
        val (step, prompt, note) = when (phase) {
            ConnectionPhase.SCANNING -> Triple(0, null, "Looking for the camera")
            ConnectionPhase.AWAITING_APPROVAL -> Triple(0, ConnectionPrompt.ApproveOnCamera(APPROVE), null)
            // The Wi-Fi step's caption is its phase, as the app has always shown it.
            ConnectionPhase.READING_WIFI_CREDS -> Triple(1, null, "Reading Wi-Fi credentials…")
            ConnectionPhase.JOINING_WIFI -> Triple(1, null, "Joining camera Wi-Fi…")
            ConnectionPhase.OPENING_DATALINK -> Triple(2, null, null)
            ConnectionPhase.LIVE -> Triple(3, null, null)
            else -> Triple(0, null, null)
        }
        return ConnectionEvent.Progress(ConnectionProgress(attempt, corePhase, STEPS, step, note), prompt)
    }

    /** The saved record after a connect: the camera's access point as the preferred route, the time. */
    private fun record(target: ConnectTarget): SavedCamera {
        val base = when (target) {
            is ConnectTarget.Saved -> target.camera
            is ConnectTarget.AddRoute -> target.camera
            is ConnectTarget.Nearby -> SavedCamera(
                id = target.camera.savedID ?: target.camera.id, integration = id,
                advertisedName = target.camera.name, model = target.camera.model,
            )
        }
        val network = port.joinedSSID.value
        val index = base.routes.indexOfFirst { it.kind == RouteKind.CAMERA_ACCESS_POINT }
        val routes = if (index >= 0) {
            base.routes.mapIndexed { i, route -> if (i == index && network != null) route.copy(network = network) else route }
        } else {
            listOf(SavedRoute(key = "ap", kind = RouteKind.CAMERA_ACCESS_POINT, network = network, bluetooth = true)) + base.routes
        }
        val ap = routes.first { it.kind == RouteKind.CAMERA_ACCESS_POINT }
        return base.copy(routes = routes, preferredRoute = ap.id, lastConnected = now())
    }
}
