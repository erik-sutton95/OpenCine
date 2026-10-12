package com.opencapture.opencine.frameio

import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.Executors
import kotlin.coroutines.CoroutineContext
import kotlin.io.path.createTempDirectory
import kotlin.test.assertTrue
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

// SIMULATED ports for the shared Frame.io owner: no account, network, keystore or `.so`.

internal val CONFIGURATION = FrameioPublicConfiguration("unit-client", "opencine-unit://oauth/callback")
internal val FRESH_TOKEN = FrameioStoredToken("unit-access", "unit-refresh", 9_999_999L, "Bearer")
internal val SAVED_DESTINATION = FrameioDestination("account", "workspace", "project", "Dailies", "folder")
internal const val UNIT_PRODUCT = "OpenCine-Unit"

internal fun controller(
    root: Path = Path.of(System.getProperty("java.io.tmpdir"), "frameio-ready"),
    configuration: () -> FrameioPublicConfiguration? = { CONFIGURATION },
    core: FakeCore = FakeCore(),
    http: FakeHttp = FakeHttp(),
    secrets: MemorySecretStore = MemorySecretStore(),
    destinations: MemoryDestinationStore = MemoryDestinationStore(),
    reachability: FrameioReachability = FixedReachability(FrameioNetworkState.ONLINE),
    approvedUploadRoots: List<Path> = listOf(root),
    uiDispatcher: CoroutineDispatcher = Dispatchers.Unconfined,
    metadataSidecarWriter: FrameioMetadataSidecarWriter = NoFrameioMetadataSidecarWriter,
    uploadHistory: FrameioUploadHistoryStore = NoFrameioUploadHistoryStore,
    clock: () -> Long = { 100_000L },
    internetWaitPoll: suspend () -> Unit = {},
    internetWaitAttempts: Int = 3,
    uploadStatusPoll: suspend () -> Unit = {},
): FrameioDeliveryController =
    FrameioDeliveryController(
        configuration = configuration,
        core = core,
        http = http,
        secretStore = secrets,
        destinationStore = destinations,
        reachability = reachability,
        approvedUploadRoots = approvedUploadRoots,
        productName = UNIT_PRODUCT,
        metadataSidecarWriter = metadataSidecarWriter,
        uploadHistory = uploadHistory,
        clock = clock,
        uiDispatcher = uiDispatcher,
        internetWaitPoll = internetWaitPoll,
        internetWaitAttempts = internetWaitAttempts,
        uploadStatusPoll = uploadStatusPoll,
    )

/** Signed in with [SAVED_DESTINATION] already chosen. */
internal fun connectedController(
    root: Path,
    core: FakeCore = FakeCore(),
    http: FakeHttp = FakeHttp(),
    reachability: FrameioReachability = FixedReachability(FrameioNetworkState.ONLINE),
    approvedUploadRoots: List<Path> = listOf(root),
    metadataSidecarWriter: FrameioMetadataSidecarWriter = NoFrameioMetadataSidecarWriter,
    uploadHistory: FrameioUploadHistoryStore = NoFrameioUploadHistoryStore,
    secrets: MemorySecretStore = MemorySecretStore(FrameioSecretState(FRESH_TOKEN, null)),
    clock: () -> Long = { 100_000L },
    uploadStatusPoll: suspend () -> Unit = {},
): FrameioDeliveryController =
    controller(
        root = root, core = core, http = http, secrets = secrets,
        destinations = MemoryDestinationStore(SAVED_DESTINATION), reachability = reachability,
        approvedUploadRoots = approvedUploadRoots, metadataSidecarWriter = metadataSidecarWriter,
        uploadHistory = uploadHistory, clock = clock, uploadStatusPoll = uploadStatusPoll,
    )

internal suspend fun withReadyRoot(block: suspend (Path) -> Unit) {
    val root = createTempDirectory("frameio-ready")
    try {
        block(root)
    } finally {
        root.toFile().deleteRecursively()
    }
}

internal fun Path.clip(name: String, size: Int = 4): Path =
    resolve(name).also { Files.write(it, ByteArray(size) { index -> (index + 1).toByte() }) }

internal class MemorySecretStore(initial: FrameioSecretState = FrameioSecretState(null, null)) : FrameioSecretStore {
    var state: FrameioSecretState = initial

    override fun load(): FrameioSecretState = state

    override fun saveToken(token: FrameioStoredToken) {
        state = FrameioSecretState(token, state.pendingAuthorization)
    }

    override fun clearToken() {
        state = FrameioSecretState(null, state.pendingAuthorization)
    }

    override fun savePendingAuthorization(pending: FrameioPendingAuthorization) {
        state = FrameioSecretState(state.token, pending)
    }

    override fun clearPendingAuthorization() {
        state = FrameioSecretState(state.token, null)
    }

    override fun clearAll() {
        state = FrameioSecretState(null, null)
    }
}

internal class MemoryDestinationStore(initial: FrameioDestination? = null) : FrameioDestinationStore {
    private var destination: FrameioDestination? = initial

    override fun load(): FrameioDestination? = destination

    override fun save(destination: FrameioDestination) {
        this.destination = destination
    }

    override fun clear() {
        destination = null
    }
}

internal class FixedReachability(private val value: FrameioNetworkState) : FrameioReachability {
    override fun state(): FrameioNetworkState = value
}

internal class SequencedReachability(values: List<FrameioNetworkState>) : FrameioReachability {
    private val values = values.iterator()
    private var last = FrameioNetworkState.OFFLINE

    override fun state(): FrameioNetworkState {
        if (values.hasNext()) last = values.next()
        return last
    }
}

internal class MutableReachability(var value: FrameioNetworkState) : FrameioReachability {
    override fun state(): FrameioNetworkState = value
}

/**
 * Scripted shared core: [partSizes] is the Create File plan and [uploadComplete] answers each
 * status poll by index (null is an undecodable status).
 */
internal class FakeCore(
    private val partSizes: List<Long> = listOf(4),
    private val mediaType: String? = "video/quicktime",
    private val uploadComplete: (Int) -> Boolean? = { true },
    private val refreshedToken: FrameioAccessToken = FrameioAccessToken("unit-access", "unit-refresh", 3_600, "Bearer"),
    var projects: List<FrameioProject> = listOf(FrameioProject("project", "Dailies", "folder")),
) : FrameioCoreBridge {
    var authorizationStarts = 0
    var redirectParses = 0
    val tokenKinds = mutableListOf<String>()
    val tokenRefreshTokens = mutableListOf<String?>()
    val apiOperations = mutableListOf<String>()
    val createdNames = mutableListOf<String>()
    val createdSizes = mutableListOf<Long>()
    val createdFolders = mutableListOf<String?>()
    var statusPolls = 0

    val tokenRequests: Int get() = tokenKinds.size

    override fun beginAuthorization(config: FrameioPublicConfiguration, nowEpochMillis: Long): FrameioAuthorizationTransaction? {
        authorizationStarts += 1
        return FrameioAuthorizationTransaction(
            authorizationURL = "https://auth.example.invalid/authorize",
            state = "unit-state",
            verifier = "v".repeat(43),
            createdAtEpochMillis = nowEpochMillis,
        )
    }

    override fun parseRedirect(config: FrameioPublicConfiguration, callbackURI: String, expectedState: String): String? {
        redirectParses += 1
        return "unit-code".takeIf {
            expectedState == "unit-state" && callbackURI == "${config.redirectURI}?code=unit-code&state=unit-state"
        }
    }

    override fun tokenRequest(
        kind: String,
        config: FrameioPublicConfiguration,
        code: String?,
        verifier: String?,
        refreshToken: String?,
    ): FrameioHttpRequest? {
        tokenKinds += kind
        tokenRefreshTokens += refreshToken
        return FrameioHttpRequest("https://ims.example.invalid/token", "POST", "redacted")
    }

    override fun apiRequest(
        operation: String,
        accountID: String?,
        workspaceID: String?,
        folderID: String?,
        fileID: String?,
        name: String?,
        fileSize: Long,
    ): FrameioHttpRequest? {
        apiOperations += operation
        if (operation == FrameioCoreOperation.CREATE_FILE) {
            createdNames += name.orEmpty()
            createdSizes += fileSize
            createdFolders += folderID
        }
        return FrameioHttpRequest("https://api.example.invalid/$operation", "GET", null)
    }

    override fun decodeToken(response: String): FrameioAccessToken? = refreshedToken

    override fun decodeProjects(response: String): List<FrameioProject>? = projects

    override fun decodeProject(response: String): FrameioProject? = FrameioProject("created", "Created", "created-folder")

    override fun decodeAccounts(response: String): List<FrameioAccount>? = listOf(FrameioAccount("account", null))

    override fun decodeWorkspaces(response: String): List<FrameioWorkspace>? = listOf(FrameioWorkspace("workspace", "Workspace"))

    override fun decodeUploadPlan(response: String): FrameioUploadPlan? =
        FrameioUploadPlan(
            fileID = "file",
            mediaType = mediaType,
            parts = partSizes.mapIndexed { index, size -> FrameioUploadPart(size, "https://uploads.example.invalid/part${index + 1}") },
        )

    override fun decodeUploadComplete(response: String): Boolean? = uploadComplete(statusPolls++)

    override fun mediaTypeFor(filename: String): String? = "application/octet-stream"
}

/** One PUT the controller sent: byte range and media type, never a bearer token. */
internal data class SentPart(val url: String, val offset: Long, val byteCount: Long, val contentType: String)

internal class FakeHttp(
    private val progressFromIO: Boolean = false,
    private val uploadFailure: Throwable? = null,
    private val failUploadCalls: Set<Int> = emptySet(),
    private val respond: (FrameioHttpRequest) -> FrameioHttpResponse = { FrameioHttpResponse(200, "{}") },
    private val onExecute: () -> Unit = {},
) : FrameioHttpClient {
    var executeCalls = 0
    var uploadCalls = 0
    val bearerTokens = mutableListOf<String?>()
    val parts = mutableListOf<SentPart>()
    var progressCallbackThreadName: String? = null

    override suspend fun execute(request: FrameioHttpRequest, bearerToken: String?, contentType: String?): FrameioHttpResponse {
        executeCalls += 1
        bearerTokens += bearerToken
        onExecute()
        return respond(request)
    }

    override suspend fun putUploadPart(
        uploadURL: String,
        source: Path,
        offset: Long,
        byteCount: Long,
        contentType: String,
        onBytesSent: suspend (Long) -> Unit,
    ): FrameioHttpResponse {
        uploadCalls += 1
        assertTrue(Files.isRegularFile(source))
        parts += SentPart(uploadURL, offset, byteCount, contentType)
        if (uploadCalls in failUploadCalls) throw java.io.IOException("unit upload failure")
        uploadFailure?.let { throw it }
        if (progressFromIO) {
            withContext(Dispatchers.IO) {
                progressCallbackThreadName = Thread.currentThread().name
                onBytesSent(byteCount)
            }
        } else {
            onBytesSent(byteCount)
        }
        return FrameioHttpResponse(200, "")
    }
}

internal class MemoryUploadHistory(initial: Set<String> = emptySet()) : FrameioUploadHistoryStore {
    private val identities = initial.toMutableSet()
    var reads = 0

    override fun wasUploaded(stableClipIdentity: String): Boolean {
        reads += 1
        return stableClipIdentity in identities
    }

    override fun recordUploaded(stableClipIdentity: String): Boolean {
        identities += stableClipIdentity
        return true
    }

    fun contains(identity: String): Boolean = identity in identities
}

internal class ThrowingUploadHistory(
    private val failRead: Boolean = false,
    private val failWrite: Boolean = false,
) : FrameioUploadHistoryStore {
    override fun wasUploaded(stableClipIdentity: String): Boolean {
        if (failRead) throw java.io.IOException("unit history read failure")
        return false
    }

    override fun recordUploaded(stableClipIdentity: String): Boolean {
        if (failWrite) throw java.io.IOException("unit history write failure")
        return true
    }
}

internal class RecordingUIDispatcher : CoroutineDispatcher(), AutoCloseable {
    private val executor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "frameio-delivery-ui") }

    override fun dispatch(context: CoroutineContext, block: Runnable) {
        executor.execute(block)
    }

    override fun close() {
        executor.shutdownNow()
    }
}

internal class FakeCameraHop(
    override val availability: FrameioHopAvailability = FrameioHopAvailability.READY,
    private val onLeave: suspend () -> Unit = {},
    private val onRejoin: suspend () -> FrameioCameraRejoinEvidence? = { FrameioCameraRejoinEvidence("Camera", "SIMULATED", 123_000L) },
) : FrameioCameraHop {
    var leaveCalls = 0
    var rejoinCalls = 0

    override suspend fun leaveCameraNetwork(): Boolean {
        leaveCalls += 1
        onLeave()
        return true
    }

    override suspend fun rejoinCameraNetwork(): FrameioCameraRejoinEvidence? {
        rejoinCalls += 1
        return onRejoin()
    }
}

internal class RecordingMetadataWriter(private val failure: Exception? = null) : FrameioMetadataSidecarWriter {
    data class Call(val facts: FrameioSidecarFacts, val deliveryFilename: String, val byteCount: Long, val destination: FrameioDestination)
    val calls = mutableListOf<Call>()

    override suspend fun recordSuccessfulDelivery(
        facts: FrameioSidecarFacts,
        deliveryFilename: String,
        byteCount: Long,
        destination: FrameioDestination,
    ) {
        calls += Call(facts, deliveryFilename, byteCount, destination)
        failure?.let { throw it }
    }
}
