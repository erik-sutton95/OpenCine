package com.opencapture.opencine.appkit

import androidx.compose.runtime.Composable
import com.opencapture.opencine.core.CameraIntegration
import com.opencapture.opencine.core.ConnectTarget
import com.opencapture.opencine.core.ConnectedCamera
import com.opencapture.opencine.core.ConnectionEvent
import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.ConnectionProgress
import com.opencapture.opencine.core.ConnectionPrompt
import com.opencapture.opencine.core.ConnectionRouteID
import com.opencapture.opencine.core.DiscoveryMode
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.IntegrationPrompt
import com.opencapture.opencine.core.NearbyCamera
import com.opencapture.opencine.core.RecoveryAction
import com.opencapture.opencine.core.RouteDraft
import com.opencapture.opencine.core.SavedCamera
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * One integration as the app lists it, with the typed slots for what only it shows (Swift
 * `AppIntegration`). Shared code never asks which integration an entry is.
 */
public class AppIntegration(public val integration: CameraIntegration, public val slots: IntegrationSlots = IntegrationSlots())

/** Integration-only views the app composes into the shared screens (extension level 3). */
public class IntegrationSlots(
    /** Pair-page content for steps only this integration has, shown while choosing a camera. */
    public val pairing: (@Composable () -> Unit)? = null,
    /** Builds a route to add to a saved camera; `null` cancels. */
    public val addRoute: (@Composable (camera: SavedCamera, done: (RouteDraft?) -> Unit) -> Unit)? = null,
    /** Renders an integration prompt; without it the prompt's text shows. */
    public val prompt: (@Composable (IntegrationPrompt) -> Unit)? = null,
)

/**
 * The shared connection flow over the app's integrations (Swift `CamerasModel`): saved cameras,
 * nearby sightings, at most one live attempt per camera, the last failure per camera and the
 * pairing state. Confine it to the main thread; [scope] runs discovery and attempts.
 *
 * Discovery: while no camera is live and no attempt runs, every integration discovers in
 * [DiscoveryMode.PASSIVE]; the pair page asks for [DiscoveryMode.ACTIVE] from the integrations
 * that list it. A stale event from an attempt the model replaced or cancelled is dropped.
 * Recovery while live stays the integration's; the app hands the live session back with
 * [sessionEnded].
 */
public class CamerasModel(
    public val entries: List<AppIntegration>,
    private val store: SavedCamerasStore,
    private val scope: CoroutineScope,
) {
    /** A camera one integration sees now. */
    public data class Sighting(public val integration: IntegrationID, public val camera: NearbyCamera) {
        public val id: String get() = camera.id
    }

    /** The live attempt for one camera. */
    public data class Attempt(
        public val target: ConnectTarget,
        public val integration: IntegrationID,
        /** `null` until the integration reports its plan. */
        public val progress: ConnectionProgress? = null,
        public val prompt: ConnectionPrompt? = null,
    ) {
        /** The route this attempt uses, when it is a saved route. */
        public val route: ConnectionRouteID? get() = (target as? ConnectTarget.Saved)?.route
    }

    /** How the last attempt for a camera ended, and what retrying it means. */
    public data class Failure(public val failure: ConnectionFailure, public val target: ConnectTarget)

    /** What a failure action asks of the app that the model cannot do itself. */
    public sealed interface Request {
        public data object OpenSettings : Request
        public data class EditRoute(public val camera: SavedCamera, public val route: ConnectionRouteID) : Request
        public data object PairAgain : Request
        public data class Integration(public val id: String, public val camera: String) : Request
    }

    public data class State(
        public val saved: List<SavedCamera> = emptyList(),
        public val nearby: List<Sighting> = emptyList(),
        /** Keyed by [ConnectTarget.cameraID]. */
        public val attempts: Map<String, Attempt> = emptyMap(),
        /** Keyed by [ConnectTarget.cameraID]; cleared by the next attempt. */
        public val failures: Map<String, Failure> = emptyMap(),
        public val connected: ConnectedCamera? = null,
        public val pairing: Boolean = false,
        /** Some integration is discovering. */
        public val scanning: Boolean = false,
        /** The sighting chosen on the pair page. */
        public val selection: String? = null,
    )

    private val mutable: MutableStateFlow<State>
    public val state: StateFlow<State>

    /** Called once per successful attempt, after the record is saved. */
    public var onConnected: (ConnectedCamera) -> Unit = {}

    private val discovery = HashMap<Int, Pair<DiscoveryMode, Job>>()
    private val tokens = HashMap<String, Any>()
    private val jobs = HashMap<String, Job>()

    init {
        store.load()
        mutable = MutableStateFlow(State(saved = store.cameras))
        state = mutable.asStateFlow()
        updateDiscovery()
    }

    private inline fun update(change: (State) -> State) {
        mutable.value = change(mutable.value)
    }

    // Discovery

    /** The mode an integration discovers in now; `null` stops it. */
    public fun discoveryMode(integration: CameraIntegration): DiscoveryMode? {
        val now = mutable.value
        if (now.connected != null || now.attempts.isNotEmpty()) return null
        if (now.pairing && DiscoveryMode.ACTIVE in integration.discoveryModes) return DiscoveryMode.ACTIVE
        return if (DiscoveryMode.PASSIVE in integration.discoveryModes) DiscoveryMode.PASSIVE else null
    }

    public fun beginPairing() {
        update { it.copy(pairing = true) }
        updateDiscovery()
    }

    public fun endPairing() {
        update { it.copy(pairing = false, selection = null) }
        updateDiscovery()
    }

    public fun select(id: String?) {
        update { it.copy(selection = id) }
    }

    private fun updateDiscovery() {
        for ((index, entry) in entries.withIndex()) {
            val wanted = discoveryMode(entry.integration)
            if (discovery[index]?.first == wanted) continue
            discovery.remove(index)?.second?.cancel()
            if (wanted == null) continue
            val id = entry.integration.id
            discovery[index] = wanted to scope.launch(start = CoroutineStart.UNDISPATCHED) {
                entry.integration.discover(wanted).collect { publish(it, id) }
            }
        }
        update { it.copy(scanning = discovery.isNotEmpty()) }
    }

    private fun publish(list: List<NearbyCamera>, integration: IntegrationID) {
        update { now -> now.copy(nearby = now.nearby.filter { it.integration != integration } + list.map { Sighting(integration, it) }) }
    }

    // Connecting

    /** Connects a saved camera over [route], else its preferred route, else its first. */
    public fun connect(camera: SavedCamera, route: ConnectionRouteID? = null) {
        val chosen = route ?: camera.preferredRoute ?: camera.routes.firstOrNull()?.id ?: return
        start(ConnectTarget.Saved(camera, chosen), camera.integration)
    }

    public fun connect(sighting: Sighting) {
        start(ConnectTarget.Nearby(sighting.camera), sighting.integration)
    }

    /** Provisions a new route on a saved camera (from an add-route slot). */
    public fun addRoute(draft: RouteDraft, camera: SavedCamera) {
        start(ConnectTarget.AddRoute(camera, draft), camera.integration)
    }

    public fun cancel(cameraID: String) {
        if (cameraID !in mutable.value.attempts) return
        tokens.remove(cameraID)
        jobs.remove(cameraID)?.cancel()
        update { it.copy(attempts = it.attempts - cameraID) }
        updateDiscovery()
    }

    public fun cancelAll() {
        for (cameraID in mutable.value.attempts.keys.toList()) cancel(cameraID)
    }

    /** The app closed the live session, or it ended: discovery resumes. */
    public fun sessionEnded() {
        update { it.copy(connected = null) }
        updateDiscovery()
    }

    /** Runs a failure's action; returns what the app must do when the model cannot. */
    public fun perform(action: RecoveryAction, cameraID: String): Request? {
        val now = mutable.value
        when (action) {
            RecoveryAction.Retry -> now.failures[cameraID]?.let { failure ->
                integrationOf(failure.target)?.let { start(failure.target, it) }
            }
            is RecoveryAction.UseRoute -> now.saved.firstOrNull { it.id == cameraID }?.let { connect(it, action.route) }
            is RecoveryAction.EditRoute ->
                return now.saved.firstOrNull { it.id == cameraID }?.let { Request.EditRoute(it, action.route) }
            RecoveryAction.PairAgain -> return Request.PairAgain
            RecoveryAction.OpenSettings -> return Request.OpenSettings
            is RecoveryAction.Integration -> return Request.Integration(action.id, cameraID)
        }
        return null
    }

    private fun integrationOf(target: ConnectTarget): IntegrationID? = when (target) {
        is ConnectTarget.Saved -> target.camera.integration
        is ConnectTarget.AddRoute -> target.camera.integration
        is ConnectTarget.Nearby -> mutable.value.nearby.firstOrNull { it.camera.id == target.camera.id }?.integration
    }

    private fun start(target: ConnectTarget, integration: IntegrationID) {
        val entry = entries.firstOrNull { it.integration.id == integration } ?: return
        val cameraID = target.cameraID
        jobs.remove(cameraID)?.cancel()
        val token = Any()
        tokens[cameraID] = token
        update { it.copy(attempts = it.attempts + (cameraID to Attempt(target, integration)), failures = it.failures - cameraID) }
        updateDiscovery()
        jobs[cameraID] = scope.launch(start = CoroutineStart.UNDISPATCHED) {
            entry.integration.connect(target).collect { apply(it, cameraID, token) }
            finish(cameraID, token)
        }
    }

    private fun apply(event: ConnectionEvent, cameraID: String, token: Any) {
        if (tokens[cameraID] !== token) return
        val attempt = mutable.value.attempts[cameraID] ?: return
        when (event) {
            is ConnectionEvent.Progress -> update {
                it.copy(attempts = it.attempts + (cameraID to attempt.copy(progress = event.progress, prompt = event.prompt)))
            }
            is ConnectionEvent.Connected -> {
                tokens.remove(cameraID)
                jobs.remove(cameraID)
                update { it.copy(attempts = it.attempts - cameraID) }
                upsert(event.camera.saved)
                update { it.copy(connected = event.camera) }
                onConnected(event.camera)
                updateDiscovery()
            }
            is ConnectionEvent.Failed -> {
                tokens.remove(cameraID)
                jobs.remove(cameraID)
                update { it.copy(attempts = it.attempts - cameraID, failures = it.failures + (cameraID to Failure(event.failure, attempt.target))) }
                updateDiscovery()
            }
        }
    }

    /** The flow ended without an outcome (the attempt was cancelled). */
    private fun finish(cameraID: String, token: Any) {
        if (tokens[cameraID] !== token) return
        tokens.remove(cameraID)
        jobs.remove(cameraID)
        update { it.copy(attempts = it.attempts - cameraID) }
        updateDiscovery()
    }

    // Saved cameras

    /**
     * The app wrote its legacy records itself (an integration whose app still saves with its own
     * rules): merges them into the document now. Call it right after each such write, so a save
     * from here never patches over it.
     */
    public fun reloadSaved() {
        store.load()
        update { it.copy(saved = store.cameras) }
    }

    /** `null` or a blank name clears the rename. */
    public fun rename(cameraID: String, name: String?) {
        val trimmed = name?.trim()?.takeIf { it.isNotEmpty() }
        edit(cameraID) { it.copy(name = trimmed) }
    }

    /** Asks the integration to drop what it stores for the camera, then removes it. */
    public suspend fun forget(cameraID: String) {
        val camera = mutable.value.saved.firstOrNull { it.id == cameraID } ?: return
        cancel(cameraID)
        entries.firstOrNull { it.integration.id == camera.integration }?.integration?.forget(camera)
        update { it.copy(failures = it.failures - cameraID) }
        save(mutable.value.saved.filter { it.id != cameraID })
    }

    public fun forgetRoute(route: ConnectionRouteID, cameraID: String) {
        edit(cameraID) { camera ->
            camera.copy(
                routes = camera.routes.filter { it.id != route },
                preferredRoute = camera.preferredRoute.takeIf { it != route },
            )
        }
    }

    private fun edit(cameraID: String, change: (SavedCamera) -> SavedCamera) {
        val saved = mutable.value.saved
        if (saved.none { it.id == cameraID }) return
        save(saved.map { if (it.id == cameraID) change(it) else it })
    }

    /**
     * Saves [camera], replacing the record with its id or adding it first: what an integration or
     * its app slot remembers outside a connect (a setup about to move the camera).
     */
    public fun upsert(camera: SavedCamera) {
        val saved = mutable.value.saved
        save(if (saved.any { it.id == camera.id }) saved.map { if (it.id == camera.id) camera else it } else listOf(camera) + saved)
    }

    private fun save(cameras: List<SavedCamera>) {
        store.save(cameras)
        update { it.copy(saved = cameras) }
    }
}
