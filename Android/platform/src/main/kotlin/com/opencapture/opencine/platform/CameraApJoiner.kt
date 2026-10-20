package com.opencapture.opencine.platform

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Handler
import android.os.Looper
import android.os.PatternMatcher
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.Socket
import kotlin.coroutines.resume
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull

/**
 * What one product changes about joining its camera's access point; the join itself is shared.
 * Values only: a product never subclasses or forks [CameraApJoiner].
 */
class CameraApJoinPolicy(
    /** Whether a scan result names the requested network. Exact SSID by default. */
    val scanMatches: (scanned: String, requested: String) -> Boolean = { scanned, requested ->
        scanned.equals(requested, ignoreCase = true)
    },
    /** Whether this phone's address on the joined network is a client address on the camera's AP. */
    val isCameraClientAddress: (String) -> Boolean = { true },
    /**
     * How long a lost Network keeps the process route before the path counts as lost. Android
     * often replaces the SoftAP Network object a few seconds after a join without the camera
     * leaving, and the retained route keeps sockets off home Wi-Fi meanwhile. Zero reports a
     * loss at once.
     */
    val reassociationGraceMillis: Long = 8_000L,
    /** Diagnostics: level, code and a message. Never carries a passphrase. */
    val log: (level: String, code: String, message: String) -> Unit = { _, _, _ -> },
)

/**
 * The one camera access-point join for every product (DJI SoftAP, Insta360 Luna, Nikon AP):
 * [WifiNetworkSpecifier] plus [ConnectivityManager.bindProcessToNetwork], so camera sockets route
 * over a network that carries no internet. The callback stays registered while the session lives
 * (unregistering tears the peer-to-peer network down), so callers [release] on teardown.
 *
 * Android's "Searching for devices" panel lists the camera only once it is in Wi-Fi scan results,
 * so [join] kicks a scan and waits briefly for the SSID first; without permission to read scan
 * results that wait is skipped, since it could only delay the join. Callbacks are fenced by
 * attempt: a cancelled or replaced join never unbinds its successor.
 */
class CameraApJoiner(context: Context, private val policy: CameraApJoinPolicy = CameraApJoinPolicy()) {
    private val appContext = context.applicationContext
    private val connectivity =
        appContext.getSystemService(ConnectivityManager::class.java)
            ?: error("ConnectivityManager unavailable")
    private val wifi = appContext.getSystemService(WifiManager::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Any()
    private val operations = CallbackOperationOwner<ConnectivityManager.NetworkCallback>()
    private val availability = CameraApAvailabilityTracker<Network>()
    private val reassociationWaiters = mutableListOf<ReassociationWaiter>()
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var joinContinuation: CancellableContinuation<Boolean>? = null
    private var boundNetwork: Network? = null
    private var reassociationGrace: Runnable? = null

    /** The path is gone: the reassociation grace expired, or Android refused the process bind. */
    var onPathLost: (() -> Unit)? = null

    /** Android replaced the camera Network object; sockets must rebind. The session stays live. */
    var onReassociated: (() -> Unit)? = null

    /** Android never shows a join dialog while the radio is off. */
    val isWifiEnabled: Boolean
        get() = wifi?.isWifiEnabled != false

    /**
     * Requests the camera network and suspends until Android connects (`true`) or declines, times
     * out or is cancelled (`false`). A user cancel of the system dialog surfaces as `false`.
     * Returns `false` at once with Wi-Fi off.
     *
     * @param matchPrefix match every SSID that starts with [ssid] (a misread name whose key is right).
     * @param hidden probe for an access point that is not beaconing yet.
     * @param preScanMillis how long to wait for [ssid] in scan results before asking Android.
     * @param requireVisible kick one more scan when the wait ends unseen, for the system panel.
     */
    suspend fun join(
        ssid: String,
        passphrase: String?,
        timeoutMillis: Int,
        wpa3: Boolean = false,
        hidden: Boolean = false,
        matchPrefix: Boolean = false,
        preScanMillis: Long = DEFAULT_PRE_SCAN_MILLIS,
        requireVisible: Boolean = false,
    ): Boolean {
        val trimmed = ssid.trim()
        if (trimmed.isEmpty()) return false
        val attempt = operations.begin()
        operations.runIfCurrent(attempt) { releaseResources() }
        try {
            if (!isWifiEnabled) {
                release(attempt)
                return false
            }
            val visible = { seen: String ->
                if (matchPrefix) seen.startsWith(trimmed, ignoreCase = true) else policy.scanMatches(seen, trimmed)
            }
            awaitScanVisibility(
                canReadScans = canReadWifiScans(appContext),
                maxWaitMillis = preScanMillis,
                requireVisible = requireVisible,
                kick = ::kickWifiScan,
                visible = { scanResultsContain(visible) },
            )
            return requestSpecifierNetwork(attempt, trimmed, passphrase, timeoutMillis, wpa3, hidden, matchPrefix)
        } catch (cancelled: CancellationException) {
            release(attempt)
            throw cancelled
        }
    }

    /** Starts a Wi-Fi scan without joining, so results are warm before the operator taps Connect. */
    fun primeScan() {
        if (isWifiEnabled) kickWifiScan()
    }

    /**
     * Uses a Wi-Fi network this phone is already on when it carries a camera client address (the
     * operator joined in Settings, or Android auto-joined): binds the process to it and watches it
     * for loss. `false` when there is none.
     */
    @Suppress("DEPRECATION")
    fun adoptJoinedNetwork(): Boolean {
        val network =
            connectivity.allNetworks.firstOrNull { candidate ->
                connectivity.getNetworkCapabilities(candidate)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true &&
                    ipv4Addresses(candidate).any(policy.isCameraClientAddress)
            } ?: return false
        val attempt = operations.begin()
        operations.runIfCurrent(attempt) { releaseResources() }
        val watch =
            object : ConnectivityManager.NetworkCallback() {
                override fun onLost(lost: Network) {
                    handleLost(attempt, this, lost)
                }
            }
        val adopted =
            operations.runIfCurrent(attempt) {
                operations.attach(attempt, watch)
                synchronized(lock) {
                    availability.requestStarted()
                    availability.onAvailable(network)
                    callback = watch
                    boundNetwork = network
                }
                connectivity.bindProcessToNetwork(network)
                connectivity.registerNetworkCallback(
                    NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(),
                    watch,
                )
            }
        if (adopted) policy.log("info", "wifi", "wifi: adopted joined camera network $network")
        return adopted
    }

    /**
     * Waits for the joined camera AP to disappear and come back (a Nikon body restarts its AP after
     * the operator accepts a first pairing). A duplicate availability of the joined network never
     * counts. `false` with no established request, when Android declares it unavailable, or after
     * [timeoutMillis]. Cancelling removes only this wait; it never releases the camera AP.
     */
    suspend fun awaitReassociation(timeoutMillis: Long): Boolean {
        require(timeoutMillis > 0L) { "timeoutMillis must be greater than zero." }
        return withTimeoutOrNull(timeoutMillis) {
            suspendCancellableCoroutine { continuation ->
                val waiter =
                    synchronized(lock) {
                        availability.nextReassociationGeneration()?.let { target ->
                            ReassociationWaiter(target, continuation).also(reassociationWaiters::add)
                        }
                    }
                if (waiter == null) {
                    continuation.resumeValue(false)
                } else {
                    continuation.invokeOnCancellation {
                        synchronized(lock) { reassociationWaiters.removeAll { it.continuation === continuation } }
                    }
                }
            }
        } ?: false
    }

    /** The bound camera network, for a socket factory. */
    fun network(): Network? = synchronized(lock) { boundNetwork }

    fun bindSocket(socket: DatagramSocket) {
        val network = network() ?: return
        runCatching { network.bindSocket(socket) }
            .onFailure { policy.log("warning", "wifi", "wifi: UDP bindSocket failed ${it.javaClass.simpleName}") }
    }

    fun bindSocket(socket: Socket) {
        val network = network() ?: return
        runCatching { network.bindSocket(socket) }
            .onFailure { policy.log("warning", "wifi", "wifi: TCP bindSocket failed ${it.javaClass.simpleName}") }
    }

    /** Bound to the camera network, or inside the reassociation grace (the route is retained). */
    fun isProcessBound(): Boolean =
        synchronized(lock) {
            isPathReady(hasBoundNetwork = boundNetwork != null, inReassociationGrace = reassociationGrace != null)
        }

    /** Revalidates the retained camera network after suspension. */
    fun hasUsableCameraNetwork(): Boolean {
        val network = network() ?: return false
        if (connectivity.boundNetworkForProcess != network) return false
        val capabilities = connectivity.getNetworkCapabilities(network) ?: return false
        return capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) && cameraLocalIPv4() != null
    }

    /** This phone's address on the camera AP, by the product's client-address rule. */
    fun cameraLocalIPv4(): String? = network()?.let(::ipv4Addresses)?.firstOrNull(policy.isCameraClientAddress)

    /** Drops the camera network: unbinds the process and unregisters the request. Safe twice. */
    fun release() {
        release(operations.begin())
    }

    private fun ipv4Addresses(network: Network): List<String> =
        connectivity.getLinkProperties(network)?.linkAddresses.orEmpty()
            .mapNotNull { (it.address as? Inet4Address)?.hostAddress }

    private fun release(attempt: CallbackOperationOwner.Token<ConnectivityManager.NetworkCallback>) {
        operations.runIfCurrent(attempt) {
            releaseResources()
            operations.finish(attempt)
        }
    }

    /** Caller holds the operation fence through process unbind and unregister. */
    private fun releaseResources() {
        val toUnregister: ConnectivityManager.NetworkCallback?
        val pending: CancellableContinuation<Boolean>?
        val waiters: List<ReassociationWaiter>
        synchronized(lock) {
            toUnregister = callback
            pending = joinContinuation
            waiters = reassociationWaiters.toList()
            callback = null
            joinContinuation = null
            reassociationWaiters.clear()
            boundNetwork = null
            availability.release()
            cancelReassociationGraceLocked()
        }
        connectivity.bindProcessToNetwork(null)
        toUnregister?.let { runCatching { connectivity.unregisterNetworkCallback(it) } }
        pending?.resumeValue(false)
        waiters.forEach { it.continuation.resumeValue(false) }
    }

    private suspend fun requestSpecifierNetwork(
        attempt: CallbackOperationOwner.Token<ConnectivityManager.NetworkCallback>,
        ssid: String,
        passphrase: String?,
        timeoutMillis: Int,
        wpa3: Boolean,
        hidden: Boolean,
        matchPrefix: Boolean,
    ): Boolean {
        val specifier =
            WifiNetworkSpecifier.Builder()
                .apply {
                    if (matchPrefix) setSsidPattern(PatternMatcher(ssid, PatternMatcher.PATTERN_PREFIX)) else setSsid(ssid)
                    if (!passphrase.isNullOrEmpty()) {
                        if (wpa3) setWpa3Passphrase(passphrase) else setWpa2Passphrase(passphrase)
                    }
                    if (hidden) setIsHiddenSsid(true)
                }
                .build()
        val request =
            NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .setNetworkSpecifier(specifier)
                .build()
        return suspendCancellableCoroutine { continuation ->
            val networkCallback =
                object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) {
                        handleAvailable(attempt, this, network)
                    }

                    override fun onUnavailable() {
                        operations.runIfCurrent(attempt, this) {
                            policy.log("info", "wifi", "wifi: join unavailable after ${timeoutMillis}ms")
                            release(attempt)
                        }
                    }

                    override fun onLost(network: Network) {
                        handleLost(attempt, this, network)
                    }
                }
            val installed =
                operations.runIfCurrent(attempt) {
                    operations.attach(attempt, networkCallback)
                    synchronized(lock) {
                        availability.requestStarted()
                        callback = networkCallback
                        joinContinuation = continuation
                    }
                }
            if (!installed) {
                continuation.resume(false)
                return@suspendCancellableCoroutine
            }
            // On the main looper: OEMs that attach the system join dialog to the foreground
            // activity's UI thread still surface it above the app's own popup.
            mainHandler.post {
                operations.runIfCurrent(attempt, networkCallback) {
                    if (!continuation.isActive) {
                        release(attempt)
                        return@runIfCurrent
                    }
                    try {
                        policy.log(
                            "info", "wifi",
                            "wifi: request $ssid timeout=${timeoutMillis}ms wpa3=$wpa3 hidden=$hidden prefix=$matchPrefix",
                        )
                        connectivity.requestNetwork(request, networkCallback, mainHandler, timeoutMillis)
                    } catch (error: RuntimeException) {
                        policy.log("info", "wifi", "wifi: request failed ${error.javaClass.simpleName}")
                        release(attempt)
                    }
                }
            }
            continuation.invokeOnCancellation { release(attempt) }
        }
    }

    private fun kickWifiScan() {
        val manager = wifi ?: return
        try {
            @Suppress("DEPRECATION")
            manager.startScan()
        } catch (_: SecurityException) {
        } catch (_: RuntimeException) {
        }
    }

    // Callers check canReadWifiScans first; a SecurityException reads as "not visible". The app
    // declares ACCESS_WIFI_STATE and ACCESS_FINE_LOCATION (a library must not request location).
    @SuppressLint("MissingPermission")
    private fun scanResultsContain(matches: (String) -> Boolean): Boolean {
        val results =
            try {
                wifi?.scanResults
            } catch (_: SecurityException) {
                null
            } ?: return false
        return results.any { result -> result.SSID?.trim()?.removeSurrounding("\"")?.let(matches) == true }
    }

    private fun handleAvailable(
        attempt: CallbackOperationOwner.Token<ConnectivityManager.NetworkCallback>,
        expectedCallback: ConnectivityManager.NetworkCallback,
        network: Network,
    ) {
        operations.runIfCurrent(attempt, expectedCallback) {
            val resumeNow: CancellableContinuation<Boolean>?
            val waiters: List<ReassociationWaiter>
            val reassociated: Boolean
            synchronized(lock) {
                if (callback !== expectedCallback) return@runIfCurrent
                val result = availability.onAvailable(network)
                if (!result.shouldBind) return@runIfCurrent
                if (!connectivity.bindProcessToNetwork(network)) {
                    val wasEstablished = result.reassociationGeneration != null
                    policy.log("error", "wifi", "wifi: process bind rejected")
                    release(attempt)
                    if (wasEstablished) onPathLost?.invoke()
                    return@runIfCurrent
                }
                boundNetwork = network
                cancelReassociationGraceLocked()
                reassociated = result.reassociationGeneration != null
                resumeNow = joinContinuation.takeIf { availability.hasEstablishedNetwork() }
                joinContinuation = null
                waiters =
                    result.reassociationGeneration?.let { generation ->
                        reassociationWaiters.filter { it.targetGeneration <= generation }
                            .also { reassociationWaiters.removeAll(it.toSet()) }
                    }.orEmpty()
            }
            policy.log("info", "wifi", "wifi: available $network reassoc=$reassociated")
            LocalVPNProbe.noteIfActive(appContext) { policy.log("notice", "vpn", it) }
            resumeNow?.resumeValue(true)
            waiters.forEach { it.continuation.resumeValue(true) }
            if (reassociated) onReassociated?.invoke()
        }
    }

    private fun handleLost(
        attempt: CallbackOperationOwner.Token<ConnectivityManager.NetworkCallback>,
        expectedCallback: ConnectivityManager.NetworkCallback,
        network: Network,
    ) {
        operations.runIfCurrent(attempt, expectedCallback) {
            synchronized(lock) {
                if (callback !== expectedCallback || !availability.onLost(network)) return@runIfCurrent
                if (boundNetwork == network) boundNetwork = null
                // Retain the process route during reassociation so sockets cannot leak onto home
                // Wi-Fi while Android replaces the camera Network.
                scheduleReassociationGraceLocked(attempt, expectedCallback)
            }
            policy.log("info", "wifi", "wifi: lost $network, waiting ${policy.reassociationGraceMillis}ms for reassociation")
        }
    }

    private fun scheduleReassociationGraceLocked(
        attempt: CallbackOperationOwner.Token<ConnectivityManager.NetworkCallback>,
        expectedCallback: ConnectivityManager.NetworkCallback,
    ) {
        cancelReassociationGraceLocked()
        lateinit var grace: Runnable
        grace =
            Runnable {
                operations.runIfCurrent(attempt, expectedCallback) {
                    val expired =
                        synchronized(lock) {
                            if (reassociationGrace !== grace) return@synchronized false
                            reassociationGrace = null
                            boundNetwork == null && availability.hasEstablishedNetwork()
                        }
                    if (expired) {
                        policy.log("info", "wifi", "wifi: reassociation grace expired")
                        connectivity.bindProcessToNetwork(null)
                        onPathLost?.invoke()
                    }
                }
            }
        reassociationGrace = grace
        mainHandler.postDelayed(grace, policy.reassociationGraceMillis)
    }

    private fun cancelReassociationGraceLocked() {
        reassociationGrace?.let { mainHandler.removeCallbacks(it) }
        reassociationGrace = null
    }

    private class ReassociationWaiter(
        val targetGeneration: Long,
        val continuation: CancellableContinuation<Boolean>,
    )

    companion object {
        /** A first-attempt scan wait: long enough for one scan cycle on most phones. */
        const val DEFAULT_PRE_SCAN_MILLIS: Long = 3_000L

        /** Wi-Fi scan results are readable: precise location granted and Location services on. */
        fun canReadWifiScans(context: Context): Boolean =
            context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED &&
                context.getSystemService(LocationManager::class.java)?.isLocationEnabled == true

        /**
         * SoftAP `onLost` nulls the [Network] at once; the process bind stays until the grace
         * expires, so a handshake or rebuild treats that window as path-ready.
         */
        fun isPathReady(hasBoundNetwork: Boolean, inReassociationGrace: Boolean): Boolean =
            hasBoundNetwork || inReassociationGrace
    }
}

/**
 * Kicks scans and waits until [visible] holds or [maxWaitMillis] passes. When scan results are
 * unreadable nothing can become visible, so it still kicks the system scan once (and once more
 * when [requireVisible]) and returns without polling: the panel lists networks from its own scan
 * even when the app may not read them (ZAB-150).
 * [requireVisible] kicks one last scan when the wait ends unseen: the system panel may still see
 * the access point.
 */
internal suspend fun awaitScanVisibility(
    canReadScans: Boolean,
    maxWaitMillis: Long,
    requireVisible: Boolean,
    kick: () -> Unit,
    visible: () -> Boolean,
    pollMillis: Long = 350L,
    rescanMillis: Long = 1_500L,
): Boolean {
    if (maxWaitMillis <= 0L) return false
    kick()
    if (!canReadScans) {
        if (requireVisible) kick()
        return false
    }
    if (visible()) return true
    var waited = 0L
    var sinceKick = 0L
    while (waited < maxWaitMillis) {
        delay(pollMillis)
        waited += pollMillis
        sinceKick += pollMillis
        if (visible()) return true
        if (sinceKick >= rescanMillis) {
            kick()
            sinceKick = 0L
        }
    }
    if (requireVisible) kick()
    return visible()
}

private fun CancellableContinuation<Boolean>.resumeValue(value: Boolean) {
    if (isActive) resume(value)
}

/**
 * The join's loss and restart contract, free of Android so it runs in JVM tests. A duplicate
 * `onAvailable` is ignored; a loss then a new network, or a replacement callback with no loss, is a
 * reassociation the live session rebinds onto instead of disconnecting. Callers serialize it.
 */
class CameraApAvailabilityTracker<NetworkToken : Any> {
    data class AvailableResult(
        val shouldBind: Boolean,
        val reassociationGeneration: Long?,
    )

    private var requestActive: Boolean = false
    private var activeNetwork: NetworkToken? = null
    private var hasEstablishedNetwork: Boolean = false
    private var awaitingReassociation: Boolean = false
    private var reassociationGeneration: Long = 0L

    /** Starts a fresh request after the previous one is released. */
    fun requestStarted() {
        requestActive = true
        activeNetwork = null
        hasEstablishedNetwork = false
        awaitingReassociation = false
        reassociationGeneration = 0L
    }

    fun onAvailable(network: NetworkToken): AvailableResult {
        if (!requestActive) return AvailableResult(shouldBind = false, reassociationGeneration = null)
        val previousNetwork = activeNetwork
        if (previousNetwork == network) return AvailableResult(shouldBind = false, reassociationGeneration = null)
        val completedReassociation = hasEstablishedNetwork && (awaitingReassociation || previousNetwork != null)
        activeNetwork = network
        hasEstablishedNetwork = true
        awaitingReassociation = false
        val generation = if (completedReassociation) ++reassociationGeneration else null
        return AvailableResult(shouldBind = true, reassociationGeneration = generation)
    }

    /** Records loss only for the owned active network: a stale callback cannot clear a newer bind. */
    fun onLost(network: NetworkToken): Boolean {
        if (activeNetwork != network) return false
        activeNetwork = null
        awaitingReassociation = true
        return true
    }

    /** Marks the request terminal without fabricating a loss. */
    fun onUnavailable() {
        requestActive = false
    }

    fun release() {
        requestActive = false
        activeNetwork = null
        hasEstablishedNetwork = false
        awaitingReassociation = false
        reassociationGeneration = 0L
    }

    /** The generation a restart wait must observe, or null unless this request joined and is live. */
    fun nextReassociationGeneration(): Long? =
        if (requestActive && hasEstablishedNetwork) reassociationGeneration + 1L else null

    fun hasEstablishedNetwork(): Boolean = hasEstablishedNetwork
}
