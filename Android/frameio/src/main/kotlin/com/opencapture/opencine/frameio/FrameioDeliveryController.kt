package com.opencapture.opencine.frameio

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.opencine.appkit.MonitorDeliveryAdmission
import com.opencapture.opencine.appkit.MonitorDeliveryInternetService
import com.opencapture.opencine.appkit.MonitorDeliveryPreparedRequest
import com.opencapture.opencine.appkit.MonitorDeliveryProject
import com.opencapture.opencine.appkit.MonitorDeliveryProjectListing
import com.opencapture.opencine.appkit.MonitorDeliveryRemoteFacts
import com.opencapture.opencine.appkit.MonitorDeliveryRemotePresentation
import com.opencapture.opencine.appkit.MonitorDeliveryRemoteRun
import com.opencapture.opencine.appkit.MonitorDeliveryRemoteService
import com.opencapture.opencine.appkit.MonitorDeliveryUploadHistory
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** Operator-visible Frame.io account state; never contains bearer material. */
enum class FrameioConnectionState {
    UNCONFIGURED,
    SIGNED_OUT,
    AUTHORIZING,
    CONNECTED,
    ERROR,
}

/** Project-list activity shown by a settings or delivery picker. */
enum class FrameioProjectState {
    IDLE,
    LOADING,
    READY,
    ERROR,
}

/** Immutable account facts returned to the shared preparation task. */
class FrameioCapturedProjectListing internal constructor(
    internal val owner: FrameioDeliveryController,
    internal val accountRevision: UUID,
    val listing: FrameioProjectListing,
)

/** Exact instance route claim; completion joins the entered leave without owning another task. */
class FrameioInternetLease internal constructor(
    internal val owner: FrameioDeliveryController,
    internal val revision: UUID,
    internal val hop: FrameioCameraHop,
    internal val admission: () -> Boolean,
) {
    internal var leaveStarted = false

    /** Whether the consented leave released the camera network; null until it finishes. */
    var leftCamera: Boolean? = null
        internal set
    internal val left = CompletableDeferred<Boolean>()
}

/** Failure whose text is intentionally free of response bodies and tokens. */
class FrameioDeliveryException(message: String) : IOException(message)

/**
 * The one Android Frame.io owner every app composes (A4-09): sign-in, token refresh, project
 * listing, the multipart upload and status poll, upload history, the metadata sidecar and the
 * explicit camera-network hop lease. It has no camera protocol knowledge; the app supplies its
 * client id, storage namespace, approved upload roots and camera-network hop adapter.
 */
@Stable
class FrameioDeliveryController(
    private val configuration: () -> FrameioPublicConfiguration?,
    private val core: FrameioCoreBridge,
    private val http: FrameioHttpClient,
    private val secretStore: FrameioSecretStore,
    private val destinationStore: FrameioDestinationStore,
    private val reachability: FrameioReachability,
    private val approvedUploadRoots: List<Path>,
    private val productName: String,
    private val metadataSidecarWriter: FrameioMetadataSidecarWriter = NoFrameioMetadataSidecarWriter,
    private val uploadHistory: FrameioUploadHistoryStore = NoFrameioUploadHistoryStore,
    private val clock: () -> Long = System::currentTimeMillis,
    private val uiDispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
    private val internetWaitPoll: suspend () -> Unit = { delay(INTERNET_WAIT_POLL_MILLIS) },
    private val internetWaitAttempts: Int = DEFAULT_INTERNET_WAIT_ATTEMPTS,
    private val uploadStatusPoll: suspend () -> Unit = { delay(UPLOAD_STATUS_POLL_DELAY_MILLIS) },
) {
    var connectionState by mutableStateOf(initialConnectionState())
        private set
    var projectState by mutableStateOf(FrameioProjectState.IDLE)
        private set
    var networkState by mutableStateOf(reachability.state())
        private set
    var projectListing by mutableStateOf<FrameioProjectListing?>(null)
        private set
    var selectedDestination by mutableStateOf(destinationStore.load())
        private set
    var internetHopState by mutableStateOf<FrameioInternetHopState>(FrameioInternetHopState.Idle)
        private set
    var cameraHopAvailability by mutableStateOf(FrameioHopAvailability.NOT_CAMERA_ACCESS_POINT)
        private set
    var errorMessage by mutableStateOf<String?>(null)
        private set

    /** Changes on every sign-in, refresh failure and disconnect; captured work checks it. */
    var accountRevision: UUID = UUID.randomUUID()
        private set
    private var cameraHop: FrameioCameraHop? = null
    private var activeCameraHop: FrameioCameraHop? = null
    private var internetLease: FrameioInternetLease? = null
    private var latestInternetLease: FrameioInternetLease? = null
    private val cameraRejoinMutex = Mutex()

    /** Whether a production Adobe client registration is available in this build. */
    val isConfigured: Boolean
        get() = configuration() != null

    /** Whether a stored session exists for a configured build. */
    val isConnected: Boolean
        get() = connectionState == FrameioConnectionState.CONNECTED

    /** True after the consented AP release and until a rejoin attempt finishes. */
    val isInternetHopActive: Boolean
        get() =
            activeCameraHop != null ||
                cameraRejoinMutex.isLocked ||
                internetHopState is FrameioInternetHopState.LeavingCamera

    init {
        require(internetWaitAttempts > 0) { "internetWaitAttempts must be positive." }
        require(approvedUploadRoots.isNotEmpty()) { "At least one approved upload root is required." }
    }

    /**
     * Attaches the current monitor's camera lifecycle owner.
     *
     * Recomposition may replace this adapter, but an already-started hop retains its exact owner
     * until rejoin finishes so it cannot return through a different saved profile.
     */
    fun attachCameraHop(hop: FrameioCameraHop?) {
        cameraHop = hop
        cameraHopAvailability = hop?.availability ?: FrameioHopAvailability.NOT_CAMERA_ACCESS_POINT
    }

    /** Refreshes visible state after app resume or settings presentation. */
    fun refresh() {
        networkState = reachability.state()
        connectionState = initialConnectionState()
        selectedDestination = destinationStore.load()
        cameraHopAvailability = cameraHop?.availability ?: FrameioHopAvailability.NOT_CAMERA_ACCESS_POINT
        if (!isInternetHopActive && internetHopState !is FrameioInternetHopState.Idle) {
            internetHopState = FrameioInternetHopState.Idle
        }
    }

    /**
     * Performs only the operator-approved first half of a camera-AP internet hop.
     *
     * The active delivery sheet remains mounted while this waits for a validated route. No cloud
     * request runs and no binding is released unless this explicit method is called.
     */
    suspend fun beginInternetHop(): Boolean {
        if (isInternetHopActive) return internetHopState is FrameioInternetHopState.Online
        val captured = claimInternetHop { true } ?: return false
        return waitInternetHop(captured)
    }

    fun claimInternetHop(admission: () -> Boolean): FrameioInternetLease? {
        networkState = reachability.state()
        if (networkState != FrameioNetworkState.CAMERA_ACCESS_POINT) {
            errorMessage = if (networkState == FrameioNetworkState.ONLINE)
                "This phone already has a validated internet route." else FrameioReachabilityPolicy.operatorMessage(networkState)
            return null
        }
        val hop = cameraHop
        cameraHopAvailability = hop?.availability ?: FrameioHopAvailability.NOT_CAMERA_ACCESS_POINT
        if (hop == null || cameraHopAvailability != FrameioHopAvailability.READY) {
            errorMessage = cameraHopAvailability.operatorMessage
            return null
        }
        if (isInternetHopActive || internetLease != null || !admission() || cameraHop !== hop ||
            isInternetHopActive || internetLease != null) return null
        val captured = FrameioInternetLease(this, UUID.randomUUID(), hop, admission)
        internetLease = captured; latestInternetLease = captured
        errorMessage = null; internetHopState = FrameioInternetHopState.LeavingCamera
        return captured.takeIf { ownsInternetHop(it) }
    }
    fun ownsInternetHop(captured: FrameioInternetLease): Boolean =
        captured.owner === this && internetLease === captured && latestInternetLease === captured
    fun endedInternetHop(captured: FrameioInternetLease): Boolean =
        captured.owner === this && internetLease == null && latestInternetLease === captured && !cameraRejoinMutex.isLocked

    fun transferInternetHop(captured: FrameioInternetLease): FrameioInternetLease? {
        if (!ownsInternetHop(captured)) return null
        val transferred = FrameioInternetLease(this, captured.revision, captured.hop, captured.admission)
        transferred.leaveStarted = captured.leaveStarted
        if (!captured.left.isCompleted) return null
        // Transfer is admitted only after the existing leave/wait has completed.
        transferred.leftCamera = captured.leftCamera
        transferred.left.complete(captured.leftCamera == true)
        internetLease = transferred; latestInternetLease = transferred
        return transferred
    }

    suspend fun waitInternetHop(captured: FrameioInternetLease): Boolean {
        if (!ownsInternetHop(captured)) return false
        if (!captured.leaveStarted) {
            if (cameraHop !== captured.hop || !captured.admission() || !ownsInternetHop(captured) ||
                cameraHop !== captured.hop) { endInternetHop(captured); return false }
            captured.leaveStarted = true
            val leftCamera = try { withContext(NonCancellable) { captured.hop.leaveCameraNetwork() } }
                catch (_: Exception) { false }
            captured.leftCamera = leftCamera
            captured.left.complete(leftCamera)
            if (!ownsInternetHop(captured)) return false
            if (!leftCamera) {
                internetLease = null
                internetHopState = FrameioInternetHopState.Failed(
                    "$productName couldn't safely disconnect the camera, so its Wi-Fi binding was not released.")
                errorMessage = (internetHopState as FrameioInternetHopState.Failed).message
                return false
            }
            activeCameraHop = captured.hop
        } else if (!captured.left.await()) return false
        if (!ownsInternetHop(captured)) return false
        internetHopState = FrameioInternetHopState.WaitingForInternet
        try {
            repeat(internetWaitAttempts) {
                if (!ownsInternetHop(captured)) return false
                val network = reachability.state()
                if (!ownsInternetHop(captured)) return false
                networkState = network
                if (network == FrameioNetworkState.ONLINE) {
                    internetHopState = FrameioInternetHopState.Online; errorMessage = null
                    return ownsInternetHop(captured)
                }
                internetWaitPoll()
            }
        } catch (error: CancellationException) {
            endInternetHop(captured)
            throw error
        }
        if (!ownsInternetHop(captured)) return false
        val timeout = "A validated internet route did not become available."
        errorMessage = timeout
        endInternetHop(captured)
        if (latestInternetLease === captured && internetHopState is FrameioInternetHopState.Failed)
            errorMessage = "$timeout Camera rejoin could not be verified."
        return false
    }

    fun endInternetHopAfterDismiss() {
        val captured = internetLease ?: return
        restoreInternetHopAfterDismiss(captured)
    }
    fun restoreInternetHopAfterDismiss(captured: FrameioInternetLease) {
        CoroutineScope(SupervisorJob() + uiDispatcher).launch {
            try { endInternetHop(captured) } catch (_: Exception) { }
        }
    }
    suspend fun endInternetHop(): Boolean {
        val captured = internetLease
        if (captured != null) return endInternetHop(captured)
        val entered = latestInternetLease ?: return internetHopState is FrameioInternetHopState.Rejoined
        // Legacy concurrent callers still join the exact already-entered attempt and result.
        return withContext(NonCancellable) {
            cameraRejoinMutex.withLock { latestInternetLease === entered &&
                internetHopState is FrameioInternetHopState.Rejoined }
        }
    }
    suspend fun endInternetHop(captured: FrameioInternetLease): Boolean = withContext(NonCancellable) {
        cameraRejoinMutex.withLock {
            if (!ownsInternetHop(captured)) return@withLock false
            // Claim once before suspension; an old caller never reads a successor's native owner.
            internetLease = null
            val leftCamera = if (captured.leaveStarted) captured.left.await() else false
            if (!leftCamera) {
                if (latestInternetLease === captured) internetHopState = FrameioInternetHopState.Idle
                return@withLock false
            }
            if (latestInternetLease !== captured) return@withLock false
            activeCameraHop = null
            internetHopState = FrameioInternetHopState.RejoiningCamera
            val evidence = try { captured.hop.rejoinCameraNetwork() } catch (_: Exception) { null }
            if (latestInternetLease !== captured) return@withLock false
            networkState = reachability.state()
            if (evidence != null) {
                internetHopState = FrameioInternetHopState.Rejoined(evidence)
                true
            } else {
                val message = "Frame.io work finished, but $productName could not verify a new camera session. " +
                    "Reconnect from Your cameras."
                internetHopState = FrameioInternetHopState.Failed(message); errorMessage = message
                false
            }
        }
    }

    /**
     * Starts an Adobe browser sign-in and persists only encrypted PKCE state.
     *
     * Returns the authorization HTTPS URL for the activity to present, or
     * null after updating [errorMessage] with a safe operator-facing reason.
     */
    fun beginSignIn(): String? {
        val config = requireConfiguration() ?: return null
        if (!requireOnline()) return null
        val transaction = core.beginAuthorization(config, clock())
        if (transaction == null) {
            failConnection("Frame.io support is unavailable in this install. Rebuild with the shared Swift core.")
            return null
        }
        secretStore.savePendingAuthorization(
            FrameioPendingAuthorization(
                redirectURI = config.redirectURI,
                state = transaction.state,
                verifier = transaction.verifier,
                createdAtEpochMillis = transaction.createdAtEpochMillis,
            ),
        )
        errorMessage = null
        connectionState = FrameioConnectionState.AUTHORIZING
        return transaction.authorizationURL
    }

    /** Clears a transaction if Android cannot hand the authorization URL to a browser. */
    fun signInBrowserUnavailable() {
        secretStore.clearPendingAuthorization()
        failConnection("Couldn't open Adobe sign-in on this device. Check for a supported browser and try again.")
    }

    /**
     * Completes a callback delivered to the manifest redirect activity. The
     * shared core verifies the exact redirect and state before Android sends a
     * token-exchange request. No callback parameter is parsed in Kotlin.
     */
    suspend fun completeRedirect(callbackURI: String) {
        val config = requireConfiguration() ?: return
        val pending = secretStore.load().pendingAuthorization
        if (pending == null || pending.redirectURI != config.redirectURI) {
            failConnection("Frame.io sign-in expired. Start it again from Settings → Storage.")
            return
        }
        if (clock() - pending.createdAtEpochMillis !in 0..MAX_PENDING_AUTH_AGE_MILLIS) {
            secretStore.clearPendingAuthorization()
            failConnection("Frame.io sign-in expired. Start it again from Settings → Storage.")
            return
        }
        if (!requireOnline()) return
        val code = core.parseRedirect(config, callbackURI, pending.state)
        if (code == null) {
            secretStore.clearPendingAuthorization()
            failConnection("Frame.io sign-in could not verify this redirect. Start it again from Settings → Storage.")
            return
        }
        try {
            val request =
                core.tokenRequest(
                    kind = TOKEN_EXCHANGE,
                    config = config,
                    code = code,
                    verifier = pending.verifier,
                ) ?: throw FrameioDeliveryException("Frame.io sign-in could not prepare a token exchange.")
            // Do not let an OAuth callback briefly switch the app away from the camera AP and
            // issue a cloud request after the initial reachability check above.
            if (!requireOnline()) return
            val response =
                http.execute(
                    request = request,
                    contentType = "application/x-www-form-urlencoded",
                )
            requireSuccess(response, "Frame.io sign-in")
            val token = core.decodeToken(response.body)
                ?: throw FrameioDeliveryException("Frame.io returned an invalid token response.")
            accountRevision = UUID.randomUUID()
            secretStore.saveToken(token.storedAt(clock()))
            secretStore.clearPendingAuthorization()
            connectionState = FrameioConnectionState.CONNECTED
            errorMessage = null
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            secretStore.clearPendingAuthorization()
            failConnection(error.operatorMessage("Frame.io sign-in failed."))
        }
    }

    /** Removes the encrypted token, pending PKCE state, and selected destination. */
    fun disconnect() {
        accountRevision = UUID.randomUUID()
        secretStore.clearAll()
        destinationStore.clear()
        selectedDestination = null
        projectListing = null
        projectState = FrameioProjectState.IDLE
        errorMessage = null
        connectionState = if (isConfigured) FrameioConnectionState.SIGNED_OUT else FrameioConnectionState.UNCONFIGURED
    }

    /** Settings facade over the same bounded native query. */
    suspend fun loadProjects() {
        projectState = FrameioProjectState.LOADING; errorMessage = null
        try {
            val captured = loadProjectsCaptured { true }
            if (!ownsProjects(captured)) return
            projectListing = captured.listing; projectState = FrameioProjectState.READY
            chooseSavedOrFirstProject(captured.listing)
        } catch (error: CancellationException) { throw error }
        catch (error: Exception) { projectState = FrameioProjectState.ERROR
            errorMessage = error.operatorMessage("Couldn't load Frame.io projects.") }
    }

    /** Native account/query port; page/loading/create policy belongs to shared Preparation. */
    suspend fun loadProjectsCaptured(current: () -> Boolean): FrameioCapturedProjectListing {
        val revision = accountRevision
        val admitted = MonitorDeliveryAdmission { accountRevision == revision && current() && accountRevision == revision }
        checkDeliveryAdmission(admitted)
        val config = requireConfiguration() ?: throw FrameioDeliveryException(errorMessage ?: "Frame.io isn't configured.")
        requireOnlineOrThrow(admitted)
        val token = accessToken(config, admitted)
        val accounts = core.decodeAccounts(apiResponse(FrameioCoreOperation.ACCOUNTS, token, admission = admitted))
            ?.takeIf { it.isNotEmpty() } ?: throw FrameioDeliveryException("Frame.io has no available account.")
        checkDeliveryAdmission(admitted)
        val account = accounts.first()
        val workspaces = core.decodeWorkspaces(apiResponse(FrameioCoreOperation.WORKSPACES, token,
            accountID = account.id, admission = admitted))?.takeIf { it.isNotEmpty() }
            ?: throw FrameioDeliveryException("Frame.io has no available workspace.")
        checkDeliveryAdmission(admitted)
        val workspace = workspaces.first()
        val projects = core.decodeProjects(apiResponse(FrameioCoreOperation.PROJECTS, token,
            accountID = account.id, workspaceID = workspace.id, admission = admitted))
            ?: throw FrameioDeliveryException("Frame.io returned an invalid project list.")
        checkDeliveryAdmission(admitted)
        return FrameioCapturedProjectListing(this, revision,
            FrameioProjectListing(account.id, workspace.id, workspace.name, projects))
    }
    fun ownsProjects(captured: FrameioCapturedProjectListing): Boolean =
        captured.owner === this && captured.accountRevision == accountRevision

    fun selectProject(project: FrameioProject): Boolean {
        val listing = projectListing ?: return false
        return selectProjectCaptured(project, FrameioCapturedProjectListing(this, accountRevision, listing)) { true }
    }
    fun selectProjectCaptured(project: FrameioProject, captured: FrameioCapturedProjectListing, current: () -> Boolean): Boolean {
        if (!ownsProjects(captured) || !current() || !ownsProjects(captured)) return false
        val listing = captured.listing
        val folder = project.rootFolderID?.takeIf { it.isNotBlank() } ?: return false
        val destination = FrameioDestination(listing.accountID, listing.workspaceID, project.id, project.name, folder)
        if (!current() || !ownsProjects(captured)) return false
        destinationStore.save(destination)
        if (!current() || !ownsProjects(captured)) return false
        selectedDestination = destination
        return true
    }

    suspend fun createProject(name: String) {
        val listing = projectListing ?: run { errorMessage = "Load Frame.io projects before creating a project."; return }
        val context = FrameioCapturedProjectListing(this, accountRevision, listing)
        projectState = FrameioProjectState.LOADING; errorMessage = null
        try {
            val created = createProjectCaptured(name, context) { true }
            if (!ownsProjects(context)) return
            projectListing = listing.copy(projects = listing.projects + created)
            projectState = FrameioProjectState.READY
            if (!selectProject(created)) errorMessage = "Frame.io created a project without an upload folder. Pick another project."
        } catch (error: CancellationException) { throw error }
        catch (error: Exception) { if (ownsProjects(context)) { projectState = FrameioProjectState.ERROR
            errorMessage = error.operatorMessage("Couldn't create the Frame.io project.") } }
    }
    suspend fun createProjectCaptured(name: String, captured: FrameioCapturedProjectListing, current: () -> Boolean): FrameioProject {
        val admitted = MonitorDeliveryAdmission { ownsProjects(captured) && current() && ownsProjects(captured) }
        checkDeliveryAdmission(admitted)
        val config = requireConfiguration() ?: throw FrameioDeliveryException(errorMessage ?: "Frame.io isn't configured.")
        requireOnlineOrThrow(admitted)
        val listing = captured.listing
        val created = core.decodeProject(apiResponse(FrameioCoreOperation.CREATE_PROJECT,
            accessToken(config, admitted), accountID = listing.accountID, workspaceID = listing.workspaceID,
            name = name, admission = admitted)) ?: throw FrameioDeliveryException("Frame.io returned an invalid project response.")
        checkDeliveryAdmission(admitted)
        return created
    }

    /** The delivery popup's remote destination over this account (A4-09). */
    fun remoteService(
        current: () -> Boolean,
        onLease: (FrameioInternetLease) -> Unit = {},
    ): MonitorDeliveryRemoteService<FrameioProject, FrameioCapturedProjectListing, FrameioInternetLease> =
        MonitorDeliveryRemoteService(
            presentation = MonitorDeliveryRemotePresentation("Frame.io", UPLOAD_CAPTION),
            observe = {
                refresh()
                MonitorDeliveryRemoteFacts(isConfigured, isConnected, networkState == FrameioNetworkState.CAMERA_ACCESS_POINT,
                    selectedDestination?.projectID, selectedDestination?.projectName)
            },
            load = {
                val listing = loadProjectsCaptured(current)
                MonitorDeliveryProjectListing(listing,
                    listing.listing.projects.filter { !it.rootFolderID.isNullOrBlank() }.take(PICKER_PROJECTS).map(::projectValue))
            },
            create = { name, context -> projectValue(createProjectCaptured(name, context, current)) },
            persist = { project, context -> selectProjectCaptured(project.payload, context, current) },
            internet = internetService(needsHop = { networkState == FrameioNetworkState.CAMERA_ACCESS_POINT }, begin = {
                val busy = isInternetHopActive || internetLease != null
                // Null only while another hop holds the route; any other refusal names its reason.
                claimInternetHop(current)?.also(onLease)
                    ?: if (busy) null else throw FrameioDeliveryException(errorMessage ?: "Camera route is no longer available.")
            }),
            transfer = { old -> transferInternetHop(old)?.also(onLease) },
            skipsUploaded = true,
        )

    /**
     * Binds one accepted request to upload services. The destination is captured once for the
     * whole run (A2-72): the project the popup selected, else the saved destination read now;
     * null when there is none. The run stays admitted only while the account it was accepted for
     * is current.
     */
    fun <R> remoteRun(
        request: MonitorDeliveryPreparedRequest<*, *, FrameioProject, FrameioCapturedProjectListing, FrameioInternetLease>,
        identity: (R) -> String?,
        sidecar: (R) -> FrameioSidecarFacts?,
        displayName: (File) -> String = { it.name },
    ): MonitorDeliveryRemoteRun<R>? {
        val context = request.projectContext?.takeIf(::ownsProjects)
        if (request.projectContext != null && context == null) return null
        val project = request.project?.payload
        val folder = project?.rootFolderID?.takeIf { it.isNotBlank() }
        val saved = selectedDestination
        val destination = when {
            project != null && folder != null && context != null -> FrameioDestination(context.listing.accountID,
                context.listing.workspaceID, project.id, project.name, folder)
            project != null -> saved?.takeIf { it.projectID == project.id && (context == null ||
                (it.accountID == context.listing.accountID && it.workspaceID == context.listing.workspaceID)) }
            else -> saved
        } ?: return null
        val revision = context?.accountRevision ?: accountRevision
        val admission = MonitorDeliveryAdmission {
            accountRevision == revision && (context == null || ownsProjects(context)) && accountRevision == revision
        }
        return MonitorDeliveryRemoteRun(
            progressCaption = UPLOAD_CAPTION,
            upload = { record, file, report ->
                upload(file.toPath(), displayName(file), destination, admission, sidecar(record), report)
            },
            history = uploadHistory(identity),
            reupload = request.configuration?.forceReupload == true,
            // The route lease travels with the request; the shared run restores it (any destination).
            admission = admission,
            routeNote = { request.internetLease?.let(::routeNote) },
        )
    }

    /** A camera rejoin that could not be verified after this run's hop is never hidden. */
    private fun routeNote(lease: FrameioInternetLease): String? {
        if (latestInternetLease !== lease) return null
        return when (val state = internetHopState) {
            is FrameioInternetHopState.Failed ->
                "camera rejoin not verified" + state.message.takeIf { it.isNotBlank() }?.let { ": $it" }.orEmpty()
            is FrameioInternetHopState.Rejoined -> "camera rejoined"
            else -> null
        }
    }

    /** Confirmed uploads keyed by a stable record identity; a blank identity is never skipped. */
    fun <R> uploadHistory(identity: (R) -> String?): MonitorDeliveryUploadHistory<R> = MonitorDeliveryUploadHistory(
        wasUploaded = { record ->
            val key = identity(record)?.takeIf { it.isNotBlank() }
            key != null && try { uploadHistory.wasUploaded(key) } catch (_: Exception) {
                throw FrameioDeliveryException("$productName couldn't read the private Frame.io upload history.")
            }
        },
        // A confirmed upload stays confirmed even when the private history rejects the write.
        recordUploaded = { record -> identity(record)?.takeIf { it.isNotBlank() }?.let { runCatching { uploadHistory.recordUploaded(it) } } },
    )

    /**
     * One upload of a prepared file: Create File, every pre-signed HTTPS part, then the status
     * poll. Progress mirrors Swift FrameioClient: 0.05 once planned, 0.1 to 0.85 over the parts,
     * 0.85 to 0.95 while Frame.io assembles the file, 1.0 when confirmed. The sidecar is written
     * only after confirmation and never fails the upload.
     */
    suspend fun upload(
        file: Path,
        displayName: String,
        destination: FrameioDestination,
        admission: MonitorDeliveryAdmission,
        sidecar: FrameioSidecarFacts?,
        progress: (Double) -> Unit,
    ) {
        suspend fun report(fraction: Double) = withContext(uiDispatcher) { progress(fraction) }
        checkDeliveryAdmission(admission)
        val byteCount = validateApprovedUpload(file, displayName)
        val config = requireConfiguration() ?: throw FrameioDeliveryException(errorMessage ?: "Frame.io isn't configured.")
        val accessToken = accessToken(config, admission)
        checkDeliveryAdmission(admission)
        val response = apiResponse(FrameioCoreOperation.CREATE_FILE, accessToken, accountID = destination.accountID,
            folderID = destination.folderID, name = displayName, fileSize = byteCount, admission = admission)
        val plan = core.decodeUploadPlan(response)
            ?: throw FrameioDeliveryException("Frame.io returned an invalid upload plan.")
        var plannedBytes = 0L
        plan.parts.forEach { part ->
            if (part.sizeBytes > byteCount - plannedBytes) {
                throw FrameioDeliveryException("Frame.io's upload plan did not match the approved media size.")
            }
            plannedBytes += part.sizeBytes
        }
        if (plannedBytes != byteCount) {
            throw FrameioDeliveryException("Frame.io's upload plan did not match the approved media size.")
        }
        val contentType = plan.mediaType ?: core.mediaTypeFor(displayName)
            ?: throw FrameioDeliveryException("Frame.io could not resolve a media type for this clip.")
        if (!contentType.isSafeMediaType()) {
            throw FrameioDeliveryException("Frame.io returned an unsafe media type for this clip.")
        }
        report(PLANNED_PROGRESS)
        var offset = 0L
        plan.parts.forEach { part ->
            requireOnlineOrThrow(admission)
            val sentBeforePart = offset
            val result = http.putUploadPart(part.url, file, offset, part.sizeBytes, contentType) { sentInPart ->
                val fraction = (sentBeforePart + sentInPart).toDouble() / byteCount.toDouble()
                // putUploadPart writes on Dispatchers.IO; publication returns to the UI dispatcher.
                report((PARTS_PROGRESS_START + (PARTS_PROGRESS_END - PARTS_PROGRESS_START) * fraction).coerceAtMost(PARTS_PROGRESS_END))
            }
            requireSuccess(result, "Frame.io upload")
            offset += part.sizeBytes
        }
        waitForUploadComplete(destination.accountID, plan.fileID, config, admission, ::report)
        if (sidecar != null) {
            try {
                metadataSidecarWriter.recordSuccessfulDelivery(sidecar, displayName, byteCount, destination)
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                // The upload is confirmed; a local sidecar is best effort.
            }
        }
    }

    private fun internetService(needsHop: () -> Boolean, begin: () -> FrameioInternetLease?) =
        MonitorDeliveryInternetService(needsHop = needsHop, begin = begin, owns = ::ownsInternetHop,
            wait = ::waitInternetHop, restoreEntered = { endInternetHop(it) }, restore = ::restoreInternetHopAfterDismiss)

    private fun projectValue(project: FrameioProject) = MonitorDeliveryProject(project.id, project.name,
        !project.rootFolderID.isNullOrBlank(), project)

    private suspend fun waitForUploadComplete(
        accountID: String,
        fileID: String,
        config: FrameioPublicConfiguration,
        admission: MonitorDeliveryAdmission,
        report: suspend (Double) -> Unit,
    ) {
        repeat(MAX_UPLOAD_STATUS_POLLS) { attempt ->
            val response = apiResponse(FrameioCoreOperation.UPLOAD_STATUS, accessToken(config, admission),
                accountID = accountID, fileID = fileID, admission = admission)
            when (core.decodeUploadComplete(response)) {
                true -> { report(1.0); return }
                false -> report(PARTS_PROGRESS_END + ASSEMBLY_PROGRESS_SHARE * attempt.toDouble() / MAX_UPLOAD_STATUS_POLLS.toDouble())
                null -> throw FrameioDeliveryException("Frame.io returned an invalid upload status.")
            }
            uploadStatusPoll()
        }
        throw FrameioDeliveryException("Frame.io did not confirm that the upload finished.")
    }

    private suspend fun apiResponse(
        operation: String,
        accessToken: String,
        accountID: String? = null,
        workspaceID: String? = null,
        folderID: String? = null,
        fileID: String? = null,
        name: String? = null,
        fileSize: Long = 0,
        admission: MonitorDeliveryAdmission? = null,
    ): String {
        requireOnlineOrThrow(admission)
        val request =
            core.apiRequest(operation, accountID, workspaceID, folderID, fileID, name, fileSize)
                ?: throw FrameioDeliveryException("Frame.io support is unavailable in this install.")
        checkDeliveryAdmission(admission)
        val response = http.execute(request, bearerToken = accessToken)
        requireSuccess(response, "Frame.io request")
        return response.body
    }

    private suspend fun accessToken(config: FrameioPublicConfiguration, admission: MonitorDeliveryAdmission? = null): String {
        checkDeliveryAdmission(admission)
        val stored = secretStore.load().token
            ?: throw FrameioDeliveryException("Sign in to Frame.io from Settings → Storage first.")
        checkDeliveryAdmission(admission)
        if (clock() < stored.expiresAtEpochMillis - REFRESH_EARLY_MILLIS) return stored.accessToken
        val refreshToken = stored.refreshToken
            ?: run {
                secretStore.clearToken()
                connectionState = FrameioConnectionState.SIGNED_OUT
                throw FrameioDeliveryException("Your Frame.io session expired. Sign in again from Settings → Storage.")
            }
        requireOnlineOrThrow(admission)
        val request =
            core.tokenRequest(
                kind = TOKEN_REFRESH,
                config = config,
                refreshToken = refreshToken,
            ) ?: throw FrameioDeliveryException("Frame.io could not prepare a token refresh.")
        checkDeliveryAdmission(admission)
        val response =
            http.execute(
                request = request,
                contentType = "application/x-www-form-urlencoded",
            )
        checkDeliveryAdmission(admission)
        if (response.statusCode !in 200..299) {
            secretStore.clearToken()
            connectionState = FrameioConnectionState.SIGNED_OUT
            throw FrameioDeliveryException("Your Frame.io session expired. Sign in again from Settings → Storage.")
        }
        val refreshed = core.decodeToken(response.body)
            ?: throw FrameioDeliveryException("Frame.io returned an invalid refreshed session.")
        val updated = refreshed.storedAt(clock(), fallbackRefreshToken = refreshToken)
        secretStore.saveToken(updated)
        connectionState = FrameioConnectionState.CONNECTED
        return updated.accessToken
    }

    private fun chooseSavedOrFirstProject(listing: FrameioProjectListing) {
        val eligible = listing.projects.filter { project -> !project.rootFolderID.isNullOrBlank() }
        val saved = selectedDestination
        val matching =
            saved?.takeIf { destination ->
                destination.accountID == listing.accountID &&
                    destination.workspaceID == listing.workspaceID &&
                    eligible.any { project -> project.id == destination.projectID }
            }
        if (matching != null) return
        eligible.firstOrNull()?.let(::selectProject)
    }

    /** Only a complete regular file under an approved root, with a safe display name, uploads. */
    private fun validateApprovedUpload(file: Path, displayName: String): Long {
        val roots = approvedUploadRoots.map { root -> root.toAbsolutePath().normalize() }
        val source = file.toAbsolutePath().normalize()
        val byteCount = runCatching { Files.size(source) }.getOrDefault(0L)
        if (
            roots.none(source::startsWith) ||
                !Files.isRegularFile(source, LinkOption.NOFOLLOW_LINKS) ||
                Files.isSymbolicLink(source) ||
                byteCount <= 0 ||
                !safeDisplayName(displayName)
        ) {
            throw FrameioDeliveryException("Only complete approved cache artifacts can be uploaded.")
        }
        return byteCount
    }

    private fun safeDisplayName(value: String): Boolean =
        value.isNotBlank() &&
            value == value.trim() &&
            !value.contains('/') &&
            !value.contains('\\') &&
            value.none { character -> character.code < 0x20 || character.code == 0x7F }

    private fun requireConfiguration(): FrameioPublicConfiguration? {
        val config = configuration()
        if (config == null) {
            connectionState = FrameioConnectionState.UNCONFIGURED
            errorMessage =
                "Frame.io isn't configured in this Android build. An approved Adobe OAuth Native App client ID and exact redirect URI are required."
        }
        return config
    }

    private fun requireOnline(): Boolean {
        networkState = reachability.state()
        if (networkState == FrameioNetworkState.ONLINE) return true
        errorMessage = FrameioReachabilityPolicy.operatorMessage(networkState)
        return false
    }

    private fun checkDeliveryAdmission(admission: MonitorDeliveryAdmission?) {
        if (admission != null && !admission.isCurrent()) throw CancellationException("Delivery source is no longer available.")
    }

    private fun requireOnlineOrThrow(admission: MonitorDeliveryAdmission? = null) {
        checkDeliveryAdmission(admission)
        val online = requireOnline()
        checkDeliveryAdmission(admission)
        if (online) return
        throw FrameioDeliveryException(errorMessage ?: "Frame.io needs a validated internet connection.")
    }

    private fun initialConnectionState(): FrameioConnectionState =
        if (configuration() == null) {
            FrameioConnectionState.UNCONFIGURED
        } else if (secretStore.load().token == null) {
            FrameioConnectionState.SIGNED_OUT
        } else {
            FrameioConnectionState.CONNECTED
        }

    private fun failConnection(message: String) {
        connectionState = FrameioConnectionState.ERROR
        errorMessage = message
    }

    private fun requireSuccess(response: FrameioHttpResponse, action: String) {
        if (response.statusCode !in 200..299) {
            throw FrameioDeliveryException("$action failed (HTTP ${response.statusCode}).")
        }
    }

    private fun FrameioAccessToken.storedAt(
        nowEpochMillis: Long,
        fallbackRefreshToken: String? = null,
    ): FrameioStoredToken {
        val lifespanMillis = expiresInSeconds.saturatingMillis()
        val expiry = if (lifespanMillis > Long.MAX_VALUE - nowEpochMillis) Long.MAX_VALUE else nowEpochMillis + lifespanMillis
        return FrameioStoredToken(
            accessToken = accessToken,
            refreshToken = refreshToken ?: fallbackRefreshToken,
            expiresAtEpochMillis = expiry,
            tokenType = tokenType,
        )
    }

    private fun Long.saturatingMillis(): Long =
        if (this > Long.MAX_VALUE / 1_000) Long.MAX_VALUE else this * 1_000

    private companion object {
        const val UPLOAD_CAPTION = "Uploading to Frame.io"
        const val PICKER_PROJECTS = 8
        const val TOKEN_EXCHANGE = "exchange"
        const val TOKEN_REFRESH = "refresh"
        const val REFRESH_EARLY_MILLIS = 60_000L
        const val MAX_PENDING_AUTH_AGE_MILLIS = 10 * 60_000L
        const val MAX_UPLOAD_STATUS_POLLS = 45
        const val UPLOAD_STATUS_POLL_DELAY_MILLIS = 2_000L
        const val PLANNED_PROGRESS = 0.05
        const val PARTS_PROGRESS_START = 0.1
        const val PARTS_PROGRESS_END = 0.85
        const val ASSEMBLY_PROGRESS_SHARE = 0.1
        const val INTERNET_WAIT_POLL_MILLIS = 500L
        const val DEFAULT_INTERNET_WAIT_ATTEMPTS = 60
    }
}

private fun Exception.operatorMessage(fallback: String): String =
    (this as? FrameioDeliveryException)?.message ?: fallback
