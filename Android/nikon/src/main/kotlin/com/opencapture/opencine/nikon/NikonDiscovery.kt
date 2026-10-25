package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.DiscoveryMode
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.PortUnreachableException
import java.net.SocketException
import java.net.SocketTimeoutException

/**
 * A device's answer on the presence port (Swift `NikonPresence`); the app decodes its own line and
 * keeps it in [line] for the fields only it reads (its relay protocol).
 */
data class NikonPresence(val deviceName: String, val servedCamera: String? = null, val line: String? = null)

/** Why discovery dials a host (Swift `NikonDialPurpose`). */
enum class NikonDialPurpose {
    /** The presence port: reaches no camera service. Presence reads and liveness. */
    PRESENCE,

    /** The camera's PTP/IP control port. */
    CAMERA_CONTROL,
}

/** One dial's result on the PTP/IP port (Swift `HostProbeVerdict`). */
enum class HostProbeVerdict {
    /** TCP accepted: something serves this port. */
    OPEN,

    /** RST: a host is there and does not serve this port (a router, a laptop, a TV). */
    REFUSED,

    /** No answer inside the budget: nobody holds the address, or nothing can reach it. */
    TIMEOUT,

    /** No route to the host: on-link and unanswered at the link layer. */
    NO_ROUTE,

    /** No route to that network at all. */
    NO_NETWORK,

    /** The OS refused the dial; says nothing about the host. */
    DENIED,

    /** Anything else, including running out of descriptors. Never evidence about the host. */
    UNREACHABLE_OTHER,
    ;

    /** Something holds this address: only an answer proves it, and a refusal is an answer. */
    val isOccupied: Boolean
        get() = when (this) {
            OPEN, REFUSED -> true
            TIMEOUT, NO_ROUTE, NO_NETWORK, DENIED, UNREACHABLE_OTHER -> false
        }

    /** The network declined to carry the dial, rather than a quiet host. */
    val isSilence: Boolean
        get() = when (this) {
            TIMEOUT, NO_ROUTE, NO_NETWORK -> true
            OPEN, REFUSED, DENIED, UNREACHABLE_OTHER -> false
        }

    companion object {
        /**
         * The verdict for a failed `Socket.connect`, read from the errno the platform reports and
         * never from the exception type alone. Android throws [ConnectException] for every errno
         * a non-blocking connect reports late, so "No route to host" from a dozing body arrives
         * as `ConnectException("... isConnected failed: EHOSTUNREACH (No route to host)")`.
         * Reading every [ConnectException] as a refusal made a silent body look occupied: the
         * pre-dial wake stopped after one dial and the doomed dial went ahead (hardware pass
         * 2026-10-25, 3.7). Only ECONNREFUSED is a refusal.
         */
        fun ofDialFailure(error: IOException): HostProbeVerdict {
            when (error) {
                is SocketTimeoutException -> return TIMEOUT
                is NoRouteToHostException -> return NO_ROUTE
                is PortUnreachableException -> return REFUSED
            }
            val text = generateSequence(error as Throwable) { it.cause }.take(4).mapNotNull { it.message }.joinToString(" ")
            return when {
                "ECONNREFUSED" in text || "Connection refused" in text -> REFUSED
                "EHOSTUNREACH" in text || "EHOSTDOWN" in text || "No route to host" in text || "Host is down" in text ->
                    NO_ROUTE
                "ENETUNREACH" in text || "Network is unreachable" in text -> NO_NETWORK
                "ETIMEDOUT" in text || "timed out" in text -> TIMEOUT
                "EACCES" in text || "EPERM" in text || "Permission denied" in text -> DENIED
                error is ConnectException -> UNREACHABLE_OTHER
                error is SocketException -> NO_NETWORK
                else -> UNREACHABLE_OTHER
            }
        }
    }
}

/**
 * Every network dial discovery makes (Swift `NikonDialer`). Presence dials can never reach a
 * camera's control service. Android names no camera with an Init (the handshake lives in the
 * Swift session), so the only camera-control dial here is a mute connect-and-hang-up.
 */
interface NikonDialer {
    suspend fun presence(host: String): NikonPresence?
    suspend fun isAlive(host: String): Boolean
    suspend fun scanControlPort(host: String, timeoutMillis: Int): HostProbeVerdict
}

/** The passive pass's dialer: presence dials go through; a camera-control dial is refused. */
internal class PassiveDialer(private val base: NikonDialer) : NikonDialer {
    override suspend fun presence(host: String) = base.presence(host)
    override suspend fun isAlive(host: String) = base.isAlive(host)
    override suspend fun scanControlPort(host: String, timeoutMillis: Int) = HostProbeVerdict.DENIED
}

data class NikonLocalInterface(val name: String, val address: String)

/** What an active search found: the hosts that accept the PTP/IP port, and what it reached. */
data class NikonSearchResult(val openHosts: List<String>, val occupiedHosts: List<String>)

/**
 * Nikon camera discovery for the cameras list and the pairing surface (Swift `NikonDiscovery`;
 * moved from OpenZCine's `RelayPresenceScanner` and `InfrastructureCameraFinder`), over a
 * [NikonDialer]. mDNS browsing stays the app's (it only listens).
 *
 * [DiscoveryMode.PASSIVE] (the list): presence sweep and liveness dials only, never the control
 * port. [DiscoveryMode.ACTIVE] (pairing): also directed probes of saved hosts, then an occupancy
 * sweep of this phone's subnets, never dialling a host another device serves.
 */
class NikonDiscovery(
    private val dialer: NikonDialer,
    private val interfaces: () -> List<NikonLocalInterface>,
    private val log: (String) -> Unit = {},
    private val nowNanos: () -> Long = System::nanoTime,
) {
    /**
     * The dial budgets are measured, not guessed: an idle ZR on Wi-Fi answers a dial in about 1.0 to
     * 1.2 s (hardware, 2026-08-04) because its radio is in power-save and listens on its beacon
     * cadence. Anything shorter measures the app's patience rather than the camera's presence.
     */
    companion object {
        const val PRESENCE_SWEEP_INTERVAL_MILLIS: Long = 30_000
        const val DIRECTED_ATTEMPT_COUNT: Int = 3
        const val DIRECTED_TIMEOUT_MILLIS: Int = 2_000
        const val BLIND_SWEEP_TIMEOUT_MILLIS: Int = 1_500
        const val SWEEP_CONCURRENCY: Int = 48
        const val LOCAL_SWEEP_PASSES: Int = 2

        /** The device among presence [hits] that names [host] as the camera it serves. */
        fun holder(host: String, hits: Map<String, NikonPresence>): String? {
            val wanted = NikonHosts.normalizedHost(host) ?: return null
            return hits.entries.sortedBy { it.key }.firstOrNull { (_, presence) ->
                presence.servedCamera?.let(NikonHosts::normalizedHost) == wanted
            }?.value?.deviceName
        }
    }

    private var lastSweepNanos: Long? = null
    private var shield: Set<String> = emptySet()

    /** Hosts the last presence sweep found serving or answering (never dialled on the control port). */
    val shieldedHosts: Set<String> get() = synchronized(this) { shield }

    /**
     * One full presence sweep of this phone's /24s, or `null` inside the rate window or with no
     * interface (no verdict, never an authoritative empty).
     */
    suspend fun presenceSweep(): Map<String, NikonPresence>? {
        val now = nowNanos()
        synchronized(this) {
            val last = lastSweepNanos
            if (last != null && now - last < PRESENCE_SWEEP_INTERVAL_MILLIS * 1_000_000) return null
            lastSweepNanos = now
        }
        val hosts = neighbours()
        if (hosts.isEmpty()) return null
        val found = LinkedHashMap<String, NikonPresence>()
        for (chunk in hosts.chunked(64)) {
            coroutineScope { chunk.map { host -> async { host to dialer.presence(host) } }.awaitAll() }
                .forEach { (host, presence) -> if (presence != null) found[host] = presence }
        }
        synchronized(this) {
            shield = found.keys + found.values.mapNotNull { it.servedCamera?.takeIf(String::isNotBlank) }
        }
        log("presence sweep hits=${found.size}")
        return found
    }

    /**
     * The device serving [host] now, from one fresh presence sweep (Swift
     * `currentHolder(of:)`). The list sweeps at most every [PRESENCE_SWEEP_INTERVAL_MILLIS], so a
     * phone that went live since is not in its held rows yet. A body that takes one initiator
     * hands its session to a new one without refusing it (a ZR drops the phone holding it), so a
     * saved connect and a recovering session ask this before they dial. Never dials a camera's
     * control port.
     */
    suspend fun currentHolder(host: String): String? {
        // A cable or a not-yet-joined access point has no network holder to ask.
        if (NikonHosts.isUsbHostKey(host) || NikonHosts.isAccessPointHostKey(host)) return null
        val found = LinkedHashMap<String, NikonPresence>()
        for (chunk in neighbours().chunked(64)) {
            coroutineScope { chunk.map { neighbour -> async { neighbour to dialer.presence(neighbour) } }.awaitAll() }
                .forEach { (neighbour, presence) -> if (presence != null) found[neighbour] = presence }
        }
        return holder(host, found)
    }

    /** Saved hosts that something occupies (a presence-port dial answered or refused). */
    suspend fun liveness(hosts: Collection<String>): Set<String> = coroutineScope {
        hosts.distinct().map { host -> async { host to dialer.isAlive(host) } }.awaitAll()
            .filter { it.second }.mapTo(linkedSetOf()) { it.first }
    }

    /**
     * The control-port search. [DiscoveryMode.PASSIVE] finds nothing and dials nothing.
     * [DiscoveryMode.ACTIVE]: directed patient probes of [directedCandidates] on this phone's
     * subnets, then an occupancy sweep stopping at the first open host. [excludedHosts] and the
     * presence shield are never dialled.
     */
    suspend fun search(
        mode: DiscoveryMode,
        directedCandidates: List<String> = emptyList(),
        excludedHosts: Set<String> = emptySet(),
    ): NikonSearchResult {
        if (mode == DiscoveryMode.PASSIVE) return NikonSearchResult(emptyList(), emptyList())
        val local = scanInterfaces()
        val subnets = local.mapNotNull { subnetBase(it.address) }.distinct().sorted()
        if (subnets.isEmpty()) return NikonSearchResult(emptyList(), emptyList())
        val locals = local.map { it.address }.toSet()
        val excluded = excludedHosts + shieldedHosts
        val directed = directedCandidates.map { it.trim() }.distinct()
            .filter { it !in excluded && it !in locals && subnetBase(it) in subnets }
        log("infra-search subnets=[${subnets.joinToString(" ")}] directed=[${directed.joinToString(" ")}]")

        // Directed first: the reconnect case answers in one round.
        val hits = coroutineScope { directed.map { host -> async { host.takeIf { patientProbe(it) } } }.awaitAll() }.filterNotNull()
        if (hits.isNotEmpty()) return NikonSearchResult(hits, hits)

        val occupied = sortedSetOf<String>()
        repeat(LOCAL_SWEEP_PASSES) { pass ->
            for (subnet in subnets) {
                if (!currentCoroutineContext().isActive) break
                val hosts = (1..254).map { "$subnet.$it" }.filterNot { it in excluded || it in locals }
                val verdicts = muteScan(hosts)
                val open = verdicts.filterValues { it == HostProbeVerdict.OPEN }.keys.sorted()
                occupied += verdicts.filterValues { it.isOccupied }.keys
                log("infra-search sweep pass=${pass + 1} subnet=$subnet open=[${open.joinToString(" ")}]")
                if (open.isNotEmpty()) return NikonSearchResult(open, occupied.toList())
            }
        }
        return NikonSearchResult(emptyList(), occupied.toList())
    }

    /** Attempts, not one long wait: a radio asleep for the first dial is awake for the second. */
    private suspend fun patientProbe(host: String): Boolean {
        repeat(DIRECTED_ATTEMPT_COUNT) {
            if (!currentCoroutineContext().isActive) return false
            if (dialer.scanControlPort(host, DIRECTED_TIMEOUT_MILLIS) == HostProbeVerdict.OPEN) return true
        }
        return false
    }

    /** Mute dials of [hosts] on the PTP/IP port, a bounded window at a time. */
    private suspend fun muteScan(hosts: List<String>): Map<String, HostProbeVerdict> {
        val verdicts = LinkedHashMap<String, HostProbeVerdict>()
        for (window in hosts.chunked(SWEEP_CONCURRENCY)) {
            if (!currentCoroutineContext().isActive) break
            coroutineScope { window.map { host -> async { host to dialer.scanControlPort(host, BLIND_SWEEP_TIMEOUT_MILLIS) } }.awaitAll() }
                .forEach { (host, verdict) -> verdicts[host] = verdict }
        }
        return verdicts
    }

    private fun neighbours(): List<String> {
        val locals = scanInterfaces().map { it.address }
        val self = locals.toSet()
        return locals.mapNotNull(::subnetBase).distinct().flatMap { base -> (1..254).map { "$base.$it" } }.filterNot(self::contains)
    }

    /** The `a.b.c` of a private (RFC 1918) IPv4 address, else `null`. */
    /** This device's interfaces discovery may scan from: never cellular or a tunnel. */
    private fun scanInterfaces(): List<NikonLocalInterface> = interfaces().filter { NikonHosts.isScanInterface(it.name, it.address) }

    private fun subnetBase(host: String): String? = host.trim().takeIf(NikonHosts::isPrivateIPv4)?.let(NikonHosts::subnetBase)
}
