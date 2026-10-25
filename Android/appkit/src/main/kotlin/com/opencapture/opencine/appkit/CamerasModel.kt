package com.opencapture.opencine.appkit

import androidx.compose.runtime.Composable
import com.opencapture.opencine.core.CameraIntegration
import com.opencapture.opencine.core.ConnectTarget
import com.opencapture.opencine.core.ConnectedCamera
import com.opencapture.opencine.core.ConfirmationPrompt
import com.opencapture.opencine.core.ConnectionEvent
import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.ConnectionProgress
import com.opencapture.opencine.core.ConnectionPrompt
import com.opencapture.opencine.core.ConnectionRouteID
import com.opencapture.opencine.core.DiscoveryMode
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.IntegrationPresentation
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
    /** The app's words for a nearby camera's card and pair-page row; null keeps the shell's. */
    public val nearbyCard: ((NearbyCamera) -> NearbyCardCopy)? = null,
    /** Typed setup capabilities and actions, preferred by the shared screen when present. */
    public val addSetup: (@Composable (camera: SavedCamera, done: (RouteDraft?) -> Unit) -> AddSetupFlow)? = null,
)

/** A nearby camera's name, subtitle and status as the app words them (a camera held by another device keeps the shell's status). */
public data class NearbyCardCopy(val name: String, val subtitle: String, val status: String)

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
    private val routePolicy: RoutePolicy = RoutePolicy.PREFERRED,
) {
    /** The shell's current operator decision; attempt retirement invalidates it before admission. */
    public val consent: OperatorConsent = OperatorConsent()

    /** The saved route a camera's card shows and a tap connects when no attempt or failure names one. */
    public enum class RoutePolicy {
        /** The camera's preferred route, else its first. */
        PREFERRED,

        /** The first route a sighting reaches ([NearbyCamera.routeKey]), else [PREFERRED]. */
        PREFER_REACHABLE,
    }

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
        /**
         * Open Settings for [reason]: a radio-off failure wants the Wi-Fi or Bluetooth panel, a
         * permission the app's own page (ZAB-245).
         */
        public data class OpenSettings(public val reason: ConnectionFailure.Reason?) : Request
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
    /** What each run's integration last reported about discovery; absent reads as running. */
    private val discoveryRunning = HashMap<Int, Boolean>()
    private val discoveryRunningJobs = HashMap<Int, Job>()
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
            discoveryRunningJobs.remove(index)?.cancel()
            if (wanted == null) {
                discoveryRunning.remove(index)
                continue
            }
            val id = entry.integration.id
            discovery[index] = wanted to scope.launch(start = CoroutineStart.UNDISPATCHED) {
                entry.integration.discover(wanted).collect { publish(it, id) }
            }
            discoveryRunning[index] = true
            discoveryRunningJobs[index] = scope.launch(start = CoroutineStart.UNDISPATCHED) {
                entry.integration.discoveryRunning.collect { running -> setDiscoveryRunning(index, running) }
            }
        }
        updateScanning()
    }

    /** A page shows scanning only while a registered run reports it can scan (IA-336). */
    private fun setDiscoveryRunning(index: Int, running: Boolean) {
        if (discoveryRunning[index] == running) return
        discoveryRunning[index] = running
        updateScanning()
    }

    private fun updateScanning() {
        update { it.copy(scanning = discovery.keys.any { index -> discoveryRunning[index] != false }) }
    }

    private fun publish(list: List<NearbyCamera>, integration: IntegrationID) {
        update { now -> now.copy(nearby = now.nearby.filter { it.integration != integration } + list.map { Sighting(integration, it) }) }
    }

    // Connecting

    /**
     * Retries the saved cameras whose last attempt failed, through a normal attempt so the card
     * and wizard show its progress. The app calls this when it returns to the foreground, as the
     * baseline backend did on its own; a live session is never re-dialled.
     */
    public fun retryCurrentFailures() {
        val now = mutable.value
        if (now.connected != null || now.pairing || now.attempts.isNotEmpty()) return
        // One backend, one connection: retry the most recent failed saved camera only, as the
        // baseline reconnected its last camera.
        val (cameraID, failure) = now.failures.entries.lastOrNull { (id, failure) ->
            failure.target is ConnectTarget.Saved && now.saved.any { it.id == id }
        } ?: return
        val camera = now.saved.first { it.id == cameraID }
        // The current record, not the failure's snapshot: a retry must not restore a renamed
        // camera or a route the operator forgot since.
        val route = (failure.target as ConnectTarget.Saved).route
        if (camera.routes.none { it.id == route }) return
        start(ConnectTarget.Saved(camera, route), camera.integration)
    }

    /** Connects a saved camera over [route], else its [defaultRoute]. */
    public fun connect(camera: SavedCamera, route: ConnectionRouteID? = null) {
        val chosen = route ?: defaultRoute(camera) ?: return
        start(ConnectTarget.Saved(camera, chosen), camera.integration)
    }

    /** The route a tap connects, by the app's [RoutePolicy]. */
    public fun defaultRoute(camera: SavedCamera): ConnectionRouteID? {
        if (routePolicy == RoutePolicy.PREFER_REACHABLE) {
            val reached = mutable.value.nearby.filter { CamerasMapping.matches(it, camera) }.mapNotNull { it.camera.routeKey }
            camera.routes.firstOrNull { it.key in reached }?.let { return it.id }
        }
        return camera.preferredRoute ?: camera.routes.firstOrNull()?.id
    }

    public fun connect(sighting: Sighting) {
        start(ConnectTarget.Nearby(sighting.camera), sighting.integration)
    }

    /**
     * A tap on a nearby camera's card: chooses it for the pair page and, when its integration
     * pairs on tap ([IntegrationPresentation.NearbyTap.CONNECT]), starts the attempt at once.
     */
    public fun openNearby(id: String) {
        select(id)
        val sighting = mutable.value.nearby.firstOrNull { it.id == id } ?: return
        if (presentation(sighting.integration).nearbyTap == IntegrationPresentation.NearbyTap.CONNECT) connect(sighting)
    }

    /** Whether [camera]'s setups take an operator name (its integration's [IntegrationPresentation.namesSetups]). */
    public fun namesSetups(camera: SavedCamera): Boolean = presentation(camera.integration).namesSetups

    private fun presentation(integration: IntegrationID): IntegrationPresentation =
        entries.firstOrNull { it.integration.id == integration }?.integration?.presentation ?: IntegrationPresentation()

    /** Provisions a new route on a saved camera (from an add-route slot). */
    public fun addRoute(draft: RouteDraft, camera: SavedCamera) {
        start(ConnectTarget.AddRoute(camera, draft), camera.integration)
    }

    public fun cancel(cameraID: String) {
        if (cameraID !in mutable.value.attempts) return
        tokens.remove(cameraID)?.let(consent::retire)
        jobs.remove(cameraID)?.cancel()
        update { it.copy(attempts = it.attempts - cameraID) }
        updateDiscovery()
    }

    public fun cancelAll() {
        for (cameraID in mutable.value.attempts.keys.toList()) cancel(cameraID)
        consent.retire()
    }

    /** Clears a camera's last failure without connecting (a pair page back to choosing). */
    public fun dismissFailure(cameraID: String) {
        update { it.copy(failures = it.failures - cameraID) }
    }

    /**
     * Re-checks every Local Network failure by connecting it again. iOS has no API to read this
     * permission, so a connect is the check; the shell calls this each time the app becomes
     * active, after the system prompt or a Settings visit. A denial that still holds fails again
     * at once with the same reason. Other failures and running attempts are left alone; one
     * integration (one backend) retries one camera, and a live camera is never replaced. A saved
     * target dials the current record, never a route the operator forgot since.
     * Swift twin: `CamerasModel.retryLocalNetworkFailures()`.
     */
    public fun retryLocalNetworkFailures() {
        if (mutable.value.connected != null) return
        val localNetwork = ConnectionFailure.Reason.Permission(ConnectionFailure.Permission.LOCAL_NETWORK)
        val retried = mutable.value.attempts.values.map { it.integration }.toMutableSet()
        for ((cameraID, failure) in mutable.value.failures.toSortedMap()) {
            if (failure.failure.reason != localNetwork || mutable.value.attempts.containsKey(cameraID)) continue
            val target = current(failure.target) ?: continue
            val integration = integrationOf(target) ?: continue
            if (retried.add(integration)) start(target, integration)
        }
    }

    /** A failure's target against the saved cameras now: `null` when its camera or route is gone. */
    private fun current(target: ConnectTarget): ConnectTarget? = when (target) {
        is ConnectTarget.Nearby -> target
        is ConnectTarget.Saved -> mutable.value.saved.firstOrNull { it.id == target.camera.id }
            ?.takeIf { camera -> camera.routes.any { it.id == target.route } }
            ?.let { ConnectTarget.Saved(it, target.route) }
        is ConnectTarget.AddRoute -> mutable.value.saved.firstOrNull { it.id == target.camera.id }
            ?.let { target.copy(camera = it) }
    }

    /**
     * The last failure a pair page shows for [selection]: the keyed one, else one whose target
     * carries that camera. A post-failure rescan clears the sightings, and the reason must stay
     * until the operator acts on it (F-PIB-042).
     */
    public fun failureFor(selection: String?): Failure? {
        if (selection == null) return null
        val now = mutable.value
        return now.failures[selection]
            ?: now.failures.values.firstOrNull { failure ->
                when (val target = failure.target) {
                    is ConnectTarget.Nearby -> target.camera.id == selection
                    is ConnectTarget.Saved -> target.camera.id == selection
                    is ConnectTarget.AddRoute -> target.camera.id == selection
                }
            }
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
            RecoveryAction.OpenSettings -> return Request.OpenSettings(now.failures[cameraID]?.failure?.reason)
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
        tokens[cameraID]?.let(consent::retire)
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
            is ConnectionEvent.Progress -> {
                update { it.copy(attempts = it.attempts + (cameraID to attempt.copy(progress = event.progress, prompt = event.prompt))) }
                val prompt = (event.prompt as? ConnectionPrompt.Integration)?.prompt as? ConfirmationPrompt
                if (prompt != null) {
                    consent.present(prompt, source = token, isCurrent = { tokens[cameraID] === token })
                } else {
                    consent.retire(token)
                }
            }
            is ConnectionEvent.Connected -> {
                tokens.remove(cameraID)?.let(consent::retire)
                jobs.remove(cameraID)
                update { it.copy(attempts = it.attempts - cameraID) }
                upsert(event.camera.saved)
                update { it.copy(connected = event.camera) }
                onConnected(event.camera)
                updateDiscovery()
            }
            is ConnectionEvent.Failed -> {
                tokens.remove(cameraID)?.let(consent::retire)
                jobs.remove(cameraID)
                update { it.copy(attempts = it.attempts - cameraID, failures = it.failures + (cameraID to Failure(event.failure, attempt.target))) }
                updateDiscovery()
            }
        }
    }

    /** The flow ended without an outcome (the attempt was cancelled). */
    private fun finish(cameraID: String, token: Any) {
        if (tokens[cameraID] !== token) return
        tokens.remove(cameraID)?.let(consent::retire)
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

    /** Renames only this setup. `null` or a blank name restores its default title. */
    public fun renameRoute(route: ConnectionRouteID, cameraID: String, name: String?) {
        if (mutable.value.attempts.isNotEmpty()) return
        if (mutable.value.saved.none { it.id == cameraID && it.routes.any { saved -> saved.id == route } }) return
        val trimmed = name?.trim()?.takeIf { it.isNotEmpty() }
        edit(cameraID) { camera -> camera.copy(routes = camera.routes.map { if (it.id == route) it.copy(title = trimmed) else it }) }
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
