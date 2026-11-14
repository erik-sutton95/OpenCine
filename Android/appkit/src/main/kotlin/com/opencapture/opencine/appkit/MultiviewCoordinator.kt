package com.opencapture.opencine.appkit

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.opencine.core.MonitorEntryID
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.MultiviewCameraPolicy
import com.opencapture.opencine.core.MultiviewMemberLink
import com.opencapture.opencine.core.MultiviewRepairContext
import com.opencapture.opencine.core.MultiviewRepairResult
import com.opencapture.opencine.core.MultiviewRepairStep
import com.opencapture.opencine.core.MultiviewLinkStatus
import com.opencapture.opencine.core.NearbyCameraScanner
import com.opencapture.opencine.core.StationCameraRecord
import com.opencapture.opencine.core.StationCommission
import com.opencapture.opencine.core.StationCommissionOutcome
import com.opencapture.opencine.core.StationCommissioner
import com.opencapture.opencine.core.StationHostPath
import com.opencapture.opencine.core.StationNetwork
import com.opencapture.opencine.core.StationRestoreResult
import com.opencapture.opencine.core.StationSubnet
import com.opencapture.opencine.core.StreamID
import com.opencapture.opencine.multicam.EditorLease
import com.opencapture.opencine.multicam.EditorLeases
import com.opencapture.opencine.multicam.RecoveryBudget
import com.opencapture.opencine.multicam.ResourceAdmission
import com.opencapture.opencine.multicam.ResourceBudget
import com.opencapture.opencine.multicam.ResourceRequest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.UUID
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * What changed on a member that the app may need to follow (its borrowed editor, its own control
 * session). Swift twin: `MultiviewMemberChange`.
 */
public enum class MultiviewMemberChange {
    /** The member's camera was replaced or cleared. */
    CAMERA,

    /** The member's control path changed: its control host, or it began connecting or recovering. */
    CONTROL,

    /** The member was removed: the app clears what it shows for it. */
    REMOVED,
}

/**
 * What only the app has, as the coordinator asks for it. Every member has a default, so an app
 * adopts only what it offers and the interface grows (Plan 4: the screen and the tile picture)
 * without breaking an adopter. Swift twin: `MultiviewHost`.
 */
public interface MultiviewHost {
    /** The operator's record confirmation preference (Settings): the stage asks before a record press when true. */
    public val confirmsRecord: Boolean get() = false

    /** Lends [slot]'s member to the app's Live View; false when it could not open. */
    public fun openLiveView(slot: Int): Boolean = false

    /** Ends any borrowed Live View; the members keep their links. */
    public fun closeLiveView() {}

    /** Closes the app's settings editors (their leases are already retired). */
    public fun closeEditors() {}

    /** A member's camera, control path or membership changed. */
    public fun memberChanged(slot: Int, change: MultiviewMemberChange) {}

    /** The app left (false) or returned to (true) the foreground. */
    public fun applicationActivityChanged(active: Boolean) {}

    /** The stage stopped: every member link is closed. */
    public fun stageStopped() {}

    /** Whether the app shows [slot]'s picture now; repairs wait while it does not. */
    public fun showsPicture(slot: Int): Boolean = true

    /** A diagnostic line (never a password). */
    public fun log(line: String) {}
}

/**
 * One slot's member as the coordinator owns it: its camera, its link's state on the stage, its
 * record state and its recovery budget. The link is the integration's; this is the stage's. Swift
 * twin: `MultiviewMember`.
 */
public class MultiviewMember<Camera>(
    /** The member's identity, kept through layout, selection and rotation. */
    public val id: UUID = UUID.randomUUID(),
    public val budget: RecoveryBudget = RecoveryBudget(2, 30.seconds),
) {
    /** The member's picture stream, named for the multicam engine. */
    public val stream: StreamID = StreamID()
    public val entryID: MonitorEntryID get() = MonitorEntryID(id)

    private var cameraState by mutableStateOf<Camera?>(null)
    public var camera: Camera?
        get() = cameraState
        set(value) {
            val old = cameraState
            cameraState = value
            val same = sameCamera
            if (same != null && !same(old, value)) onChange?.invoke(MultiviewMemberChange.CAMERA)
        }

    /** The identity the camera proved; null until it did. */
    public var identity: ByteArray? by mutableStateOf(null)

    /** Where the member was last opened; empty until then. */
    public var address: String by mutableStateOf("")
    public var status: String by mutableStateOf(MultiviewCopy.ADD_CAMERA)
    public var failureMessage: String? by mutableStateOf(null)

    private var connectingState by mutableStateOf(false)
    public var connecting: Boolean
        get() = connectingState
        set(value) {
            connectingState = value
            if (value) onChange?.invoke(MultiviewMemberChange.CONTROL)
        }

    private var recoveringState by mutableStateOf(false)
    public var recovering: Boolean
        get() = recoveringState
        set(value) {
            recoveringState = value
            if (value) onChange?.invoke(MultiviewMemberChange.CONTROL)
        }

    private var controlHostState by mutableStateOf<String?>(null)

    /** The host the member is controlled through, once its link reported `CONTROLLING`. */
    public var controlHost: String?
        get() = controlHostState
        set(value) {
            val old = controlHostState
            controlHostState = value
            if (old != value) onChange?.invoke(MultiviewMemberChange.CONTROL)
        }
    public var networkVerified: Boolean by mutableStateOf(false)

    /** Joined through the experimental shared Wi-Fi path. */
    public var experimental: Boolean by mutableStateOf(false)

    /** The link publishes a picture: from a started preview until the next open, a failed Reconnect or Remove. */
    public var publishing: Boolean by mutableStateOf(false)

    /** A record command on this member waits for its confirmation. */
    public var recordingBusy: Boolean by mutableStateOf(false)

    /** The camera's record state is fresh enough to plan a record press with. */
    public var recordingAvailable: Boolean by mutableStateOf(false)
    public var recordingNote: String? by mutableStateOf(null)
    public var lutEnabled: Boolean by mutableStateOf(true)

    /** When (coordinator clock, milliseconds) this phone lost the shared network while the member published. */
    public var pathLostAtMillis: Long? = null

    internal var onChange: ((MultiviewMemberChange) -> Unit)? = null
    internal var sameCamera: ((Camera?, Camera?) -> Boolean)? = null
    internal var repairJob: Job? = null
}

/** Where the stage journal lives (the app's preferences). Swift twin: `MultiviewJournalStorage`. */
public class MultiviewJournalStorage(
    public val load: () -> MultiviewStageJournal.Stage?,
    /** Null deletes it. False when it was not written. */
    public val save: (MultiviewStageJournal.Stage?) -> Boolean,
)

/** The app's saved shared networks. Swift twin: `MultiviewNetworkStorage`. */
public class MultiviewNetworkStorage(
    /** The saved password for a network, null when none is saved. */
    public val password: (ssid: String, hotspot: Boolean) -> String?,
    public val save: (StationNetwork) -> Unit,
)

/** The coordinator's operator copy, the same in every app. Swift twin: `MultiviewCopy`. */
public object MultiviewCopy {
    public const val ADD_CAMERA: String = "Add camera"
    public const val APPROVE_ON_CAMERA: String = "Connecting · approve on camera"
    public const val CONNECTING_PREVIEW: String = "Connecting normal preview"
    public const val WAITING_FOR_VIDEO: String = "Waiting for video"
    public const val LIVE: String = "Live · Video mode"
    public const val RECONNECTING: String = "Reconnecting…"
    public const val COULD_NOT_CONNECT: String = "Could not connect"
    public const val COULD_NOT_CONNECT_PREVIEW: String = "Could not connect preview"
    public const val COULD_NOT_RESTORE: String = "Could not restore preview. Tap Reconnect to try again."
    public const val SHARED_NETWORK_LOST: String = "Shared network unavailable. Rejoin it, then reconnect this camera."
    public const val NOT_FOUND: String =
        "Could not find this camera on the shared Wi-Fi. Check that both devices use the same network and that client isolation is off, then tap Reconnect."
    public const val UNAVAILABLE_ADDRESS: String =
        "Camera discovery returned an unavailable address. Tap Reconnect to search again."
    public const val UNSUPPORTED_SUBNET: String =
        "Automatic discovery needs a shared IPv4 network with at most 1,022 device addresses."
    public const val DUPLICATE: String = "This camera is already in Multiview."
    public const val VERIFIED_WITHOUT_PREVIEW: String = "Wi-Fi join verified · Preview not supported yet"
    public const val NOT_QUALIFIED: String = "Multiview preview is not available for this camera model yet."
    public const val JOIN_NETWORK_FIRST: String = "Join the shared Wi-Fi network on this device first."
    public const val NOT_NEARBY: String = "Camera is not nearby. Check that it is powered on."
    public const val CHECK_NETWORK: String = "Check the network name and password."
    public const val CLEANUP_NOT_SAVED: String = "Could not save camera Wi-Fi cleanup. Try again."
    public const val SCAN_CLEANUP_FAILED: String =
        "Camera Wi-Fi could not be restored. Keep it powered on and close Multiview to retry."
    public const val CLOSE_CLEANUP_FAILED: String =
        "Some cameras could not return to their own Wi-Fi. Keep them powered on and close Multiview again to retry."

    /** The search line while the stage looks for a member on the shared network. */
    public fun finding(attempt: Int, of: Int): String = "Finding camera on Wi-Fi · $attempt of $of"
}

/** Why a coordinator step failed, with its operator copy. Swift twin: `MultiviewStageFailure`. */
public sealed class MultiviewStageFailure(message: String) : Exception(message) {
    /** This phone is not on the shared network. */
    public class Network : MultiviewStageFailure(MultiviewCopy.JOIN_NETWORK_FIRST)

    /** No nearby camera to use. */
    public class Unavailable : MultiviewStageFailure(MultiviewCopy.NOT_NEARBY)

    /** Another member already holds the camera that answered. Final: the search stops. */
    public class Duplicate : MultiviewStageFailure(MultiviewCopy.DUPLICATE)
    public class Message(text: String) : MultiviewStageFailure(text)
}

/** The stage stopped under a step (Swift: `CancellationError`); the step ends without copy. */
private class StageStopped : Exception("Multiview stage stopped")

/**
 * The Bluetooth turns of member repairs: one holder at a time, in request order, never while an
 * add commissions a camera or a network scan uses the radio.
 */
internal class MultiviewBluetoothQueue {
    private val waiters = ArrayDeque<CompletableDeferred<Boolean>>()
    private var held = false

    /** Adds and scans use Bluetooth now. */
    var othersUsing: () -> Boolean = { false }

    /** The stage still runs. */
    var open: () -> Boolean = { true }

    suspend fun turn(): (() -> Unit)? {
        if (!open()) return null
        if (!held && waiters.isEmpty() && !othersUsing()) {
            held = true
            return release()
        }
        val waiter = CompletableDeferred<Boolean>()
        waiters.addLast(waiter)
        val granted = try {
            waiter.await()
        } catch (e: CancellationException) {
            waiters.remove(waiter)
            // Granted while the caller was cancelled: hand the turn on.
            if (waiter.isCompleted && !waiter.isCancelled && waiter.getCompleted()) {
                held = false
                pump()
            }
            throw e
        }
        return if (granted) release() else null
    }

    /** Grants the next turn when Bluetooth is free. */
    fun pump() {
        if (waiters.isEmpty()) return
        if (!open()) {
            stop()
            return
        }
        if (held || othersUsing()) return
        held = true
        waiters.removeFirst().complete(true)
    }

    /** Answers every waiter with no turn (the stage stopped). */
    fun stop() {
        val pending = waiters.toList()
        waiters.clear()
        for (waiter in pending) waiter.complete(false)
    }

    private fun release(): () -> Unit {
        var released = false
        return {
            if (!released) {
                released = true
                held = false
                pump()
            }
        }
    }
}

/**
 * One Multiview stage: up to `links.size` cameras on one shared network, each through its own
 * member link, with the rules every app shares (the reference Multiview session's rules). It
 * drives cameras only through the Core seams; what only the app has arrives through [host].
 * Main-thread confined: [scope] runs on the app's main dispatcher. Swift twin: `MultiviewCoordinator`.
 *
 * @param links one member link per slot, for the stage's lifetime.
 * @param members the members, when the app's link objects present their state; else new ones.
 * @param commissioner moves a nearby camera onto the network; null when cameras join only from
 *   their own menus (the camera is then opened at its sighting and its proof is kept).
 * @param scanner nearby discovery for the Add list; null when the integration has none.
 * @param describe the camera's journal record (its id is the camera's identity on the stage).
 * @param budget the app's qualification (default: one entry per link).
 * @param sightingAddress the address an integration that does not discover by probe saw the camera at.
 * @param failureMessage the operator copy for a failed add (default: the error's message).
 * @param probeWidth probes per batch while searching the subnet.
 * @param clock the coordinator's clock in milliseconds (record report freshness, path loss, grace).
 * @param monotonic the host clock the sessions stamp on (record plans, recovery budgets).
 */
public class MultiviewCoordinator<Camera, Link : MultiviewMemberLink<Camera>>(
    public val links: List<Link>,
    members: List<MultiviewMember<Camera>>? = null,
    internal val policy: MultiviewCameraPolicy<Camera>,
    private val commissioner: StationCommissioner<Camera>?,
    private val scanner: NearbyCameraScanner<Camera>?,
    public val hostPath: StationHostPath,
    internal val describe: (Camera) -> StationCameraRecord,
    private val journal: MultiviewJournalStorage,
    private val networks: MultiviewNetworkStorage,
    scope: CoroutineScope,
    budget: ResourceBudget? = null,
    private val sightingAddress: ((Camera) -> String?)? = null,
    failureMessage: ((Throwable) -> String)? = null,
    probeWidth: Int = 64,
    internal val clock: () -> Long = System::currentTimeMillis,
    internal val monotonic: () -> MonotonicInstant = { MonotonicInstant.now() },
) {
    public val members: List<MultiviewMember<Camera>> = members ?: links.map { MultiviewMember() }
    public var host: MultiviewHost? = null

    /** Layout, selection and Fit/Fill. */
    public val presentation: MultiviewStageState = MultiviewStageState(links.size)

    /** Nearby cameras the Add list offers, as the scanner reported them. */
    public var found: List<Camera> by mutableStateOf(emptyList())

    /** A network scan holds Bluetooth. */
    public var busy: Boolean by mutableStateOf(false)

    /** This phone is on the shared network. */
    public var ready: Boolean by mutableStateOf(false)
    public var ssid: String by mutableStateOf("")
    public var usePhoneHotspot: Boolean by mutableStateOf(false)
    public var password: String by mutableStateOf("")

    /** This phone's address on the joined Wi-Fi. */
    public var hostAddress: String by mutableStateOf("")
    public var networkConfigured: Boolean by mutableStateOf(false)
    public var configuringNetwork: Boolean by mutableStateOf(false)
    public var networkSetupError: String? by mutableStateOf(null)
    public var error: String? by mutableStateOf(null)
    public var closing: Boolean by mutableStateOf(false)
    public var groupRecordingBusy: Boolean by mutableStateOf(false)
    public var groupRecordingNote: String? by mutableStateOf(null)
    private var activeState by mutableStateOf(true)
    public val applicationActive: Boolean get() = activeState
    public var running: Boolean by mutableStateOf(false)
        private set

    /** Settings-editor leases: one per open editor, asked before every setting change. */
    public val editorLeases: EditorLeases = EditorLeases()

    internal var pendingReset: List<MultiviewStageJournal.Camera> by mutableStateOf(emptyList())

    private val tasks = CoroutineScope(scope.coroutineContext + SupervisorJob(scope.coroutineContext[Job]))
    private val resourceBudget = budget ?: ResourceBudget(links.size)
    private val failureText: (Throwable) -> String = failureMessage ?: { it.message ?: it.toString() }
    private val probeWidth = probeWidth.coerceAtLeast(1)
    internal val bluetooth = MultiviewBluetoothQueue()

    private var activityGeneration = 0
    private var foregroundAtMillis = Long.MIN_VALUE / 2
    private val connectionJobs = mutableMapOf<Int, Job>()
    private var hostJoin: Deferred<Unit>? = null
    private val addressReservations = mutableMapOf<String, UUID>()
    private val stationResetTasks = mutableMapOf<String, Deferred<StationRestoreResult>>()
    private val deferredReturns = mutableMapOf<String, String>()
    private var cleanupJournalWritten = false
    private var scanJob: Job? = null
    private var scanGeneration = 0
    private var networkScanJob: Deferred<Unit>? = null
    private var discovering = false
    private var monitor: Job? = null

    init {
        require(this.members.size == links.size && links.isNotEmpty())
        for (slot in links.indices) {
            val member = this.members[slot]
            links[slot].onStatus = { status -> show(status, slot) }
            member.sameCamera = { old, new -> old?.let { describe(it).id } == new?.let { describe(it).id } }
            member.onChange = { change -> host?.memberChanged(slot, change) }
        }
        bluetooth.othersUsing = { busy || connectingCameras }
        bluetooth.open = { running }
    }

    // State

    public val connectingCameras: Boolean get() = members.any { it.connecting }
    internal val assigned: Boolean get() = members.any { it.camera != null }

    /** Cleanup is left from an earlier close: the stage is closed and cameras still need to go back to their own Wi-Fi. */
    public val hasPendingCleanup: Boolean get() = !running && pendingReset.isNotEmpty() && !closing
    public val stationNetwork: StationNetwork get() = StationNetwork(ssid, password, usePhoneHotspot)

    /**
     * The coordinator's half of a member link's status: the member's copy, and the control host it
     * records once the link's control path is up at the address it was opened at.
     */
    public fun show(status: MultiviewLinkStatus, slot: Int) {
        val member = members[slot]
        when (status) {
            MultiviewLinkStatus.OPENING -> member.status = MultiviewCopy.CONNECTING_PREVIEW
            MultiviewLinkStatus.CONTROLLING -> {
                member.controlHost = member.address
                member.failureMessage = null
            }
            MultiviewLinkStatus.AWAITING_PICTURE -> member.status = MultiviewCopy.WAITING_FOR_VIDEO
            MultiviewLinkStatus.LIVE -> if (member.status != MultiviewCopy.LIVE) member.status = MultiviewCopy.LIVE
            MultiviewLinkStatus.RECONNECTING -> member.status = MultiviewCopy.RECONNECTING
        }
    }

    internal fun sameCamera(a: Camera, b: Camera): Boolean = describe(a).id == describe(b).id

    // Lifecycle

    /**
     * Opens the stage: always asks for a network, starts with empty slots, takes presentation and
     * cleanup from the journal, and runs the 1 s monitor.
     */
    public fun start() {
        if (running) return
        running = true
        hostAddress = ""
        ready = false
        networkConfigured = false
        ssid = ""
        password = ""
        usePhoneHotspot = false
        restoreStage()
        scan()
        monitor = tasks.launch {
            while (isActive) {
                delay(1.seconds)
                tick()
            }
        }
    }

    /** Stops every link, task and scan. The journal keeps what close needs. */
    public fun stop() {
        closeEditors()
        persistStage()
        hostJoin?.cancel()
        hostJoin = null
        for (job in connectionJobs.values) job.cancel()
        connectionJobs.clear()
        commissioner?.closeCommissions()
        closeLiveView()
        running = false
        setApplicationActive(true)
        monitor?.cancel()
        stopDiscovery()
        networkScanJob?.cancel()
        ready = false
        password = ""
        for (slot in links.indices) {
            members[slot].repairJob?.cancel()
            links[slot].close()
        }
        bluetooth.stop()
        host?.stageStopped()
    }

    internal suspend fun tick() {
        ready = hostPath.address(usePhoneHotspot) != null
        for (slot in links.indices) {
            links[slot].keepalive()
            val member = members[slot]
            val fresh = links[slot].recordReport?.let { clock() - it.receivedAtMillis < 3_000 } == true
            val available = member.controlHost != null && fresh
            if (member.recordingAvailable != available) member.recordingAvailable = available
            monitorPreview(slot)
        }
    }

    // Nearby discovery

    private val discoveryNeeded: Boolean
        get() = needsDiscovery(
            running && !closing, applicationActive, members.any { it.camera == null }, connectingCameras,
        )

    /** Starts (or restarts) nearby discovery when something needs it, else stops it. */
    public fun scan() {
        scanJob?.cancel()
        val scanner = scanner
        if (!discoveryNeeded || scanner == null) {
            stopDiscovery()
            return
        }
        discovering = true
        scanGeneration += 1
        val generation = scanGeneration
        scanJob = tasks.launch {
            if (!scanner.waitUntilReady()) return@launch
            ensureActive()
            found = emptyList()
            scanner.scan { camera ->
                if (scanGeneration == generation && found.none { sameCamera(it, camera) }) {
                    found = found + camera
                }
            }
        }
    }

    private fun stopDiscovery() {
        scanJob?.cancel()
        scanGeneration += 1
        scanner?.stop()
        discovering = false
    }

    /**
     * Follows demand without restarting a running scan (that clears [found]) or starting one while
     * a network scan owns the radio.
     */
    internal fun refreshDiscovery() {
        if (!discoveryNeeded) {
            if (discovering) stopDiscovery()
        } else if (!discovering && !busy) {
            scan()
        }
    }

    // Network

    /**
     * The setup wizard's scan through a nearby camera; its cleanup is journaled before the camera
     * leaves its access point.
     */
    public suspend fun scanNetworks(onFound: (String) -> Unit) {
        val commissioner = commissioner
        if (!running || closing || busy || assigned || commissioner == null) throw CancellationException("no scan")
        busy = true
        val job = tasks.async {
            var camera: Camera? = null
            for (attempt in 0 until 10) {
                ensureActive()
                camera = found.firstOrNull { policy.hasPreview(it) }
                if (camera != null) break
                delay(300.milliseconds)
            }
            val chosen = camera ?: throw MultiviewStageFailure.Unavailable()
            stopDiscovery()
            val id = describe(chosen).id
            commissioner.scanNetworks(
                chosen,
                beforeStationChange = {
                    if (!recordStationChange(chosen)) throw MultiviewStageFailure.Message(MultiviewCopy.CLEANUP_NOT_SAVED)
                },
                onRestored = { restored ->
                    if (restored) {
                        pendingReset = pendingReset.filter { it.id != id }
                        if (pendingReset.isEmpty()) networkSetupError = null
                        persistStage()
                    } else {
                        networkSetupError = MultiviewCopy.SCAN_CLEANUP_FAILED
                    }
                },
                onFound = onFound,
            )
        }
        networkScanJob = job
        try {
            job.await()
        } catch (e: CancellationException) {
            job.cancel()
            throw e
        } finally {
            busy = false
            networkScanJob = null
            refreshDiscovery()
            bluetooth.pump()
        }
    }

    /** Journals [camera] for cleanup before it leaves its own access point. */
    public fun recordStationChange(camera: Camera): Boolean {
        val record = describe(camera)
        val saved = MultiviewStageJournal.Camera(
            slot = 0, id = record.id, name = record.name, modelId = record.modelId, identity = null,
            deviceAddress = record.deviceAddress, address = "", experimental = false, lutEnabled = false,
        )
        pendingReset = MultiviewStageJournal.cleanupTargets(pendingReset, listOf(saved))
        return persistStage()
    }

    public fun selectNetworkSource(hotspot: Boolean) {
        if (configuringNetwork || assigned) return
        usePhoneHotspot = hotspot
        ssid = ""
        password = ""
        invalidateNetworkConfirmation()
    }

    public fun selectNetwork(name: String) {
        if (configuringNetwork || assigned) return
        if (ssid != name) {
            ssid = name
            password = networks.password(name, usePhoneHotspot) ?: ""
        }
        invalidateNetworkConfirmation()
    }

    private fun invalidateNetworkConfirmation() {
        networkConfigured = false
        networkSetupError = null
        hostAddress = ""
        ready = false
    }

    /** Joins this phone to the chosen Wi-Fi (never to its own hotspot); one join at a time. */
    public suspend fun joinSharedNetwork() {
        hostJoin?.let { return it.await() }
        // Lazy: registered before it runs, so a join that ends at once never leaves a stale entry.
        val job = tasks.async(start = CoroutineStart.LAZY) { performHostJoin() }
        hostJoin = job
        try {
            job.await()
        } finally {
            if (hostJoin === job) hostJoin = null
        }
        currentCoroutineContext().ensureActive()
        if (!running) throw StageStopped()
    }

    private suspend fun performHostJoin() {
        if (ssid.isEmpty()) throw MultiviewStageFailure.Network()
        // The host phone must not try joining its own hotspot. Its local bridge may appear only
        // after the first camera associates.
        if (usePhoneHotspot) return
        val address = hostPath.join(StationNetwork(ssid, password, false)) ?: throw MultiviewStageFailure.Network()
        hostAddress = address
        ready = true
    }

    /** The wizard's Connect: checks the credentials a camera can carry, joins, saves the network. */
    public suspend fun configureNetwork(): Boolean {
        if (busy || configuringNetwork || assigned) return false
        configuringNetwork = true
        networkSetupError = null
        try {
            if (ssid.isEmpty() || ssid.toByteArray().size > 32 || password.toByteArray().size > 63) {
                throw MultiviewStageFailure.Message(MultiviewCopy.CHECK_NETWORK)
            }
            joinSharedNetwork()
            networks.save(stationNetwork)
            networkConfigured = true
            persistStage()
            return true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            networkSetupError = e.message
            return false
        } finally {
            configuringNetwork = false
        }
    }

    // Foreground

    /** The app left or returned to the foreground. Members keep their links; repairs wait 3 s after a return. */
    public fun setApplicationActive(active: Boolean) {
        if (applicationActive == active) return
        activeState = active
        activityGeneration += 1
        host?.log("multiview: scene ${if (active) "active" else "inactive"}")
        if (active) foregroundAtMillis = clock()
        host?.applicationActivityChanged(active)
        refreshDiscovery()
    }

    /** Holds repairs for the foreground grace again (the app rebuilt its pictures). */
    public fun restartRepairGrace() {
        foregroundAtMillis = clock()
    }

    // Members

    /** Starts adding [camera] to [slot] unless that slot is busy. */
    public fun enqueueAdd(camera: Camera, slot: Int, experimental: Boolean = false) {
        val member = members[slot]
        if (!running || !networkConfigured || closing || member.camera != null || member.connecting) return
        connectionJobs[slot]?.cancel()
        connectionJobs[slot] = tasks.launch { add(camera, slot, experimental) }
    }

    /**
     * Adds [camera] to [slot]: the host joins, the commissioner moves the camera onto the shared
     * network (or, without one, the camera is opened where it was seen), and the camera is found
     * and identified there before its picture starts.
     */
    public suspend fun add(camera: Camera, slot: Int, experimental: Boolean = false) {
        val member = members[slot]
        val reasons = ResourceAdmission.reasons(
            ResourceRequest(member.entryID, null, emptyList()),
            policy.qualification(camera, experimental),
            members.filter { it.camera != null }.map { ResourceRequest(it.entryID, null, emptyList()) },
            resourceBudget,
        )
        if (reasons.isNotEmpty()) {
            error = MultiviewCopy.NOT_QUALIFIED
            return
        }
        if (!running || !networkConfigured || closing || busy || member.connecting || member.camera != null ||
            members.any { other -> other.camera?.let { sameCamera(it, camera) } == true }
        ) {
            return
        }
        member.connecting = true
        var client: StationCommission? = null
        member.camera = camera
        member.experimental = experimental
        member.networkVerified = false
        member.status = MultiviewCopy.APPROVE_ON_CAMERA
        refreshDiscovery()
        persistStage()
        var stage = "host Wi-Fi"
        try {
            joinSharedNetwork()
            val commissioner = commissioner
            if (commissioner == null) {
                stage = "LAN discovery"
                discoverPreview(slot, camera, null)
                networks.save(stationNetwork)
                return
            }
            stage = "Bluetooth pairing"
            val link = commissioner.connect(camera) { member.status = it }
            client = link
            stage = "camera Wi-Fi identity"
            val identity = link.identity()
            stage = "station join"
            val outcome = link.join(
                stationNetwork, identity, experimental,
                progress = { member.status = it },
                verifyOnNetwork = {
                    discoverPreview(slot, camera, identity)
                    true
                },
            )
            member.identity = identity
            networks.save(stationNetwork)
            if (outcome == StationCommissionOutcome.VERIFIED) return
            link.close()
            client = null
            stage = "LAN discovery"
            discoverPreview(slot, camera, identity)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (!running || e is StageStopped) return
            links[slot].close()
            member.status = MultiviewCopy.COULD_NOT_CONNECT
            member.failureMessage = failureText(e)
            host?.log("multiview: add failed stage=$stage error=${e.javaClass.simpleName}")
            // Keep the member for a discovery retry after a successful join.
        } finally {
            member.connecting = false
            client?.close()
            if (running) persistStage()
            refreshDiscovery()
            bluetooth.pump()
        }
    }

    /** The operator's Reconnect: the known camera first, then its setup again. */
    public suspend fun reconnect(slot: Int) {
        val member = members[slot]
        val camera = member.camera
        if (busy || member.connecting || member.recovering || camera == null) return
        member.failureMessage = null
        member.budget.reset()
        if (member.identity != null) {
            connectPreview(slot)
            if (running && currentCoroutineContext().isActive && member.failureMessage != null) readd(slot)
        } else {
            member.camera = null
            add(camera, slot, member.experimental)
        }
    }

    private suspend fun readd(slot: Int) {
        val member = members[slot]
        val camera = member.camera ?: return
        val experimental = member.experimental
        val lutEnabled = member.lutEnabled
        if (!remove(slot)) return
        member.lutEnabled = lutEnabled
        add(camera, slot, experimental)
    }

    /** Sets the camera up again through the experimental shared Wi-Fi path. */
    public suspend fun tryExperimentalNetwork(slot: Int) {
        val camera = members[slot].camera ?: return
        if (!remove(slot)) return
        add(camera, slot, true)
    }

    /** Finds the member's known camera on the shared network again and restarts its picture. */
    public suspend fun connectPreview(slot: Int) {
        val member = members[slot]
        val camera = member.camera
        val identity = member.identity
        if (!running || closing || busy || member.connecting || camera == null || identity == null) return
        member.connecting = true
        try {
            discoverPreview(slot, camera, identity)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (!running || e is StageStopped) return
            links[slot].close()
            member.publishing = false
            member.controlHost = null
            member.status = MultiviewCopy.COULD_NOT_CONNECT_PREVIEW
            member.failureMessage =
                if (e is MultiviewStageFailure.Duplicate) MultiviewCopy.DUPLICATE else MultiviewCopy.COULD_NOT_RESTORE
            member.budget.exhaust()
        } finally {
            member.connecting = false
            if (running) persistStage()
        }
    }

    /**
     * The known address first, then the subnet in two passes (other members excluded), or only the
     * known address when the integration's cameras are never probed.
     */
    private suspend fun discoverPreview(slot: Int, camera: Camera, identity: ByteArray?) {
        val member = members[slot]
        val link = links[slot]
        link.close()
        member.controlHost = null
        member.recordingAvailable = false
        val excluded = members.filter { it !== member }.mapNotNull { it.controlHost }.map(policy::hostKey).toSet()
        suspend fun attempt(): Boolean = try {
            openPreview(slot, camera, identity)
            true
        } catch (e: CancellationException) {
            throw e
        } catch (e: StageStopped) {
            throw e
        } catch (e: MultiviewStageFailure.Duplicate) {
            throw e
        } catch (e: Exception) {
            false
        }
        if (StationSubnet.validAddress(member.address) && attempt()) return
        if (!policy.discoversByProbe) {
            val sighted = sightingAddress?.invoke(camera)
            if (sighted != null && sighted != member.address && StationSubnet.validAddress(sighted)) {
                member.address = sighted
                if (attempt()) return
            }
            throw MultiviewStageFailure.Message(MultiviewCopy.NOT_FOUND)
        }
        for (pass in 1..2) {
            if (!running) throw StageStopped()
            member.status = MultiviewCopy.finding(pass, 2)
            val candidates = probeCandidates(link, excluded)
            for (address in candidates) {
                if (!running) throw StageStopped()
                member.address = address
                if (attempt()) return
                link.close()
                member.controlHost = null
            }
            if (pass == 1) delay(3.seconds)
        }
        throw MultiviewStageFailure.Message(MultiviewCopy.NOT_FOUND)
    }

    /** Hosts on this phone's subnet where a camera of the link's integration answers, [probeWidth] at a time, at most eight. */
    private suspend fun probeCandidates(link: Link, excluded: Set<String>): List<String> {
        val local = hostPath.address(usePhoneHotspot)
        val mask = hostPath.netmask(usePhoneHotspot)
        val all = if (local != null && mask != null) StationSubnet.hosts(local, mask) else null
        all ?: throw MultiviewStageFailure.Message(MultiviewCopy.UNSUPPORTED_SUBNET)
        val hosts = all.filter { policy.hostKey(it) !in excluded }
        val network = stationNetwork
        val found = mutableListOf<String>()
        for (batch in hosts.chunked(probeWidth)) {
            currentCoroutineContext().ensureActive()
            if (!running) throw StageStopped()
            val answered = coroutineScope { batch.map { host -> async { link.probe(host, network) } }.awaitAll() }
            found += batch.filterIndexed { index, _ -> answered[index] }
            if (found.size >= 8) break
        }
        return found.take(8)
    }

    private suspend fun openPreview(slot: Int, camera: Camera, identity: ByteArray?) {
        val member = members[slot]
        val link = links[slot]
        val address = member.address
        val key = policy.hostKey(address)
        val holder = addressReservations[key]
        if (holder != null && holder != member.id) throw MultiviewStageFailure.Unavailable()
        addressReservations[key] = member.id
        try {
            if (!running || !StationSubnet.validAddress(address) ||
                members.any { it !== member && it.controlHost?.let(policy::hostKey) == key }
            ) {
                throw MultiviewStageFailure.Message(MultiviewCopy.UNAVAILABLE_ADDRESS)
            }
            member.publishing = false
            val proven = link.open(camera, address, identity, stationNetwork)
            if (members.any { it !== member && it.identity?.contentEquals(proven) == true }) {
                link.close()
                throw MultiviewStageFailure.Duplicate()
            }
            if (!running) throw StageStopped()
            if (identity == null) member.identity = proven
            member.networkVerified = true
            if (!policy.hasPreview(camera)) {
                link.close()
                member.failureMessage = null
                member.status = MultiviewCopy.VERIFIED_WITHOUT_PREVIEW
                host?.log("multiview: experimental LAN identity verified; preview unavailable")
                return
            }
            link.startPreview(camera)
            member.publishing = true
        } finally {
            if (addressReservations[key] == member.id) addressReservations.remove(key)
        }
    }

    /** Clears [slot]. Its camera stays on the shared network and keeps recording; no camera command is sent. */
    public fun remove(slot: Int): Boolean {
        val member = members[slot]
        if (busy || member.connecting || groupRecordingBusy || member.recordingBusy) return false
        member.repairJob?.cancel()
        member.repairJob = null
        member.recovering = false
        member.budget.reset()
        member.pathLostAtMillis = null
        member.failureMessage = null
        links[slot].close()
        member.camera = null
        member.networkVerified = false
        member.experimental = false
        member.lutEnabled = true
        member.identity = null
        member.controlHost = null
        member.recordingAvailable = false
        member.recordingNote = null
        member.publishing = false
        member.status = MultiviewCopy.ADD_CAMERA
        member.onChange?.invoke(MultiviewMemberChange.REMOVED)
        persistStage()
        refreshDiscovery()
        return true
    }

    // Repair

    /**
     * The coordinator's half of repair: when a member may repair, the 45 s path-loss rule, and the
     * rejoin within the member's budget. The member's link decides and runs the repair.
     */
    private fun monitorPreview(slot: Int) {
        val member = members[slot]
        val link = links[slot]
        val now = clock()
        if (!applicationActive || now - foregroundAtMillis <= 3_000 || busy || member.recovering ||
            member.budget.exhausted || !member.publishing || member.connecting || member.camera == null ||
            host?.showsPicture(slot) == false
        ) {
            return
        }
        val pathReady = hostPath.address(usePhoneHotspot) != null
        if (pathReady) {
            member.pathLostAtMillis = null
        } else if (member.pathLostAtMillis == null) {
            member.pathLostAtMillis = now
        }
        val generation = activityGeneration
        val context = MultiviewRepairContext(
            pathReady = pathReady,
            running = { running },
            applicationActive = { applicationActive },
            foregroundUnchanged = { activityGeneration == generation },
            pathAvailable = { hostPath.address(usePhoneHotspot) != null },
            beginAttempt = { member.budget.beginAttempt() },
            observeHealth = { healthy -> member.budget.observe(healthy, monotonic()) },
            bluetoothTurn = { bluetooth.turn() },
        )
        when (val step = link.repair(context)) {
            MultiviewRepairStep.Healthy -> {
                if (!pathReady && now - (member.pathLostAtMillis ?: now) > 45_000) {
                    member.budget.exhaust()
                    member.failureMessage = MultiviewCopy.SHARED_NETWORK_LOST
                }
            }
            MultiviewRepairStep.Handled -> Unit
            is MultiviewRepairStep.WaitForOperator -> waitForOperator(member, step.message)
            is MultiviewRepairStep.Repair -> {
                member.recovering = true
                val deadline = link.repairDeadline
                member.repairJob = tasks.launch {
                    try {
                        when (val result = MultiviewRepairResult.race(deadline, tasks, step.run)) {
                            MultiviewRepairResult.Done -> Unit
                            MultiviewRepairResult.Rejoin -> rejoinWhenAvailable(slot)
                            is MultiviewRepairResult.WaitForOperator -> waitForOperator(member, result.message)
                        }
                    } finally {
                        member.recovering = false
                        member.repairJob = null
                    }
                }
            }
        }
    }

    /** No automatic repair remains for this member: it shows why and offers Reconnect. */
    private fun waitForOperator(member: MultiviewMember<Camera>, message: String) {
        member.budget.exhaust()
        member.failureMessage = message
    }

    private suspend fun rejoinWhenAvailable(slot: Int) {
        val member = members[slot]
        // One discovery owner; waiting members do not spend their budget.
        while (busy && running) delay(200.milliseconds)
        if (!running || member.camera == null) return
        if (!member.budget.beginAttempt()) {
            member.failureMessage = MultiviewCopy.COULD_NOT_RESTORE
            return
        }
        connectPreview(slot)
    }

    // Live View and editors

    /** Lends [slot]'s member to the app's Live View once its control path is up. Any settings editor closes first. */
    public fun openLiveView(slot: Int): Boolean {
        closeEditors()
        val member = members[slot]
        if (member.camera == null || member.controlHost == null || member.recovering) return false
        return host?.openLiveView(slot) ?: false
    }

    public fun closeLiveView() {
        host?.closeLiveView()
    }

    /**
     * Whether the stage admits a settings change on [slot] now (the app adds what only it knows,
     * such as its link and a borrowed Live View).
     */
    public fun controlsAvailable(slot: Int): Boolean {
        val member = members[slot]
        return member.camera != null && member.controlHost != null && !member.connecting && !member.recovering &&
            !busy && !closing && applicationActive && member.recordingAvailable && !groupRecordingBusy &&
            !member.recordingBusy
    }

    /**
     * Opens the one editor lease on [slot] (closing any other); null when the member cannot be
     * edited. The lease names the member's session and control epoch.
     */
    public fun openEditorLease(slot: Int): EditorLease? {
        closeEditors()
        return runCatching {
            editorLeases.open(members[slot].entryID, multicamGroup(listOf(slot)), multicamSnapshot(listOf(slot)))
        }.getOrNull()
    }

    /** Whether [lease] still admits a change on [slot] (not retired, member editable). */
    public fun editorAdmits(lease: EditorLease, slot: Int): Boolean =
        editorLeases.refusal(lease, multicamGroup(listOf(slot)), multicamSnapshot(listOf(slot))) == null &&
            controlsAvailable(slot)

    public fun closeEditors() {
        editorLeases.closeAll()
        host?.closeEditors()
    }

    // Journal

    private fun savedCameras(): List<MultiviewStageJournal.Camera> = members.mapIndexedNotNull { slot, member ->
        val camera = member.camera ?: return@mapIndexedNotNull null
        val record = describe(camera)
        MultiviewStageJournal.Camera(
            slot = slot, id = record.id, name = record.name, modelId = record.modelId, identity = member.identity,
            deviceAddress = record.deviceAddress, address = member.address, experimental = member.experimental,
            lutEnabled = member.lutEnabled,
        )
    }

    /** Writes the journal: presentation, members and cleanup; deletes it when nothing is left. */
    public fun persistStage(): Boolean {
        if (!networkConfigured && pendingReset.isEmpty()) {
            if (!cleanupJournalWritten) return true
            val success = journal.save(null)
            if (success) cleanupJournalWritten = false
            return success
        }
        val saved = savedCameras()
        val success = journal.save(
            MultiviewStageJournal.Stage(
                ssid = if (networkConfigured) ssid else "",
                hotspot = usePhoneHotspot,
                layout = presentation.layout.rawValue,
                focusedIndex = presentation.selected,
                cameras = saved,
                pendingReset = if (running && !closing) {
                    MultiviewStageJournal.cleanupTargets(pendingReset, saved)
                } else {
                    pendingReset
                },
                returnedToCameraWiFi = !running && pendingReset.isEmpty(),
                fill = presentation.fill,
            ),
        )
        if (!success) host?.log("multiview: could not save stage")
        if (success && !networkConfigured) cleanupJournalWritten = true
        return success
    }

    /** Restores from the saved journal (when valid for this stage's slots). */
    public fun restoreStage() {
        restoreStage(journal.load()?.validated(links.size))
    }

    /**
     * A new stage always asks for a network and starts with empty slots. A saved stage supplies
     * presentation and cleanup obligations only; it never chooses a network or reconnects cameras.
     */
    public fun restoreStage(saved: MultiviewStageJournal.Stage?) {
        val stage = saved ?: return
        pendingReset = stage.pendingReset.orEmpty()
        if (stage.returnedToCameraWiFi != true) {
            pendingReset = MultiviewStageJournal.cleanupTargets(pendingReset, stage.cameras)
        }
        cleanupJournalWritten = pendingReset.isNotEmpty()
        presentation.importLegacy(
            MultiviewStagePreferences(
                layout = if (stage.layout == MultiviewStageLayout.GRID.rawValue) {
                    MultiviewStageLayout.GRID
                } else {
                    MultiviewStageLayout.CENTER_STAGE
                },
                selected = stage.focusedIndex,
                fill = stage.fill == true,
            ),
        )
        // Migrate unfinished camera cleanup before a new camera is added. With no cleanup, retain
        // the last preferences even if setup is cancelled.
        if (cleanupJournalWritten) persistStage()
    }

    // Close

    /**
     * Closes every member's link first, then returns each camera to its own access point in
     * parallel. Unfinished returns stay in the journal for the next close.
     */
    public suspend fun closeStage(): Boolean {
        closeEditors()
        if (closing) return false
        closing = true
        networkScanJob?.let { job ->
            job.cancel()
            runCatching { job.join() }
        }
        if (running) pendingReset = MultiviewStageJournal.cleanupTargets(pendingReset, savedCameras())
        persistStage()
        stop()
        coroutineScope {
            for (saved in pendingReset) launch { resetStationOnce(saved) }
        }
        persistStage()
        closing = false
        if (pendingReset.isNotEmpty()) {
            error = pendingReset.firstNotNullOfOrNull { deferredReturns[it.id] } ?: MultiviewCopy.CLOSE_CLEANUP_FAILED
            return false
        }
        return true
    }

    /**
     * One camera's return, shared by a scan's completion, close and restored cleanup. Its task
     * survives the caller's cancellation and prevents two returns for the same camera.
     */
    public suspend fun resetStationOnce(saved: MultiviewStageJournal.Camera): Boolean {
        stationResetTasks[saved.id]?.let { return it.await() == StationRestoreResult.Restored }
        if (pendingReset.none { it.id == saved.id }) return true
        val commissioner = commissioner
        val task = tasks.async(start = CoroutineStart.LAZY) {
            val result = commissioner?.restoreAccessPoint(
                StationCameraRecord(saved.id, saved.name, saved.modelId, saved.deviceAddress),
            ) ?: StationRestoreResult.Restored
            when (result) {
                StationRestoreResult.Restored -> {
                    pendingReset = pendingReset.filter { it.id != saved.id }
                    deferredReturns.remove(saved.id)
                }
                is StationRestoreResult.Deferred -> deferredReturns[saved.id] = result.message
                StationRestoreResult.Failed -> deferredReturns.remove(saved.id)
            }
            persistStage()
            stationResetTasks.remove(saved.id)
            result
        }
        stationResetTasks[saved.id] = task
        return task.await() == StationRestoreResult.Restored
    }

    public companion object {
        /**
         * Nearby discovery feeds the Add list and network setup, and stays up while a camera
         * connects. A full stage, or an inactive app with nothing connecting, has no consumer for it.
         */
        public fun needsDiscovery(
            running: Boolean,
            applicationActive: Boolean,
            hasEmptySlot: Boolean,
            connecting: Boolean,
        ): Boolean = running && (hasEmptySlot || connecting) && (applicationActive || connecting)
    }
}
