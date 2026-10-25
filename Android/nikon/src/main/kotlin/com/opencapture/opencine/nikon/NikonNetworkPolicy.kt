package com.opencapture.opencine.nikon

import java.util.Locale

/*
 * The Android owner of the Nikon network policies Swift owns in OpenCineNikon (`CameraWiFiSSID`,
 * `CameraDiscovery`, `InfrastructureDiscovery`). Kotlin re-implements them so discovery stays
 * JVM-testable without the Swift library; `Fixtures/nikon-network-vectors.tsv` pins both shells to
 * the same answers (`NikonNetworkVectorTest`, Swift `NikonNetworkVectorTests`). Change one, change
 * both, and the vectors.
 */

/** Nikon Z camera access-point names (Swift `CameraWiFiSSID`). */
object NikonAccessPointSsid {
    /** The ZR's access-point prefix (`NIKON_ZR_01234`). */
    const val ZR_PREFIX: String = "NIKON_ZR_"

    /** The brand prefix every Nikon Z access point shares. */
    const val BRAND_PREFIX: String = "NIKON"

    /**
     * Whether an SSID has the conservative shape of a Nikon Z camera access point: the brand
     * prefix, a Z-series marker, at least one digit, 8 to 32 UTF-8 bytes, and only the ASCII
     * letters, digits, `_` and `-` camera-generated names use. Swift `isNikonZAccessPoint`.
     */
    fun isNikonZAccessPoint(rawSsid: String): Boolean {
        val ssid = rawSsid.trim()
        if (ssid.toByteArray(Charsets.UTF_8).size !in 8..32) return false
        val upper = ssid.uppercase(Locale.ROOT)
        if (!upper.startsWith(BRAND_PREFIX)) return false
        val suffix = upper.removePrefix(BRAND_PREFIX)
        if ('Z' !in suffix || suffix.none(Char::isDigit)) return false
        return suffix.all { it.code <= 0x7F && (it.isLetterOrDigit() || it == '_' || it == '-') }
    }

    /**
     * The model prefix an Android join falls back to when an exact SSID join fails: a misread
     * name whose key is right still joins, and only a Nikon Z network can match. Null for any
     * other name. Android only: iOS joins by prefix only when no SSID is known at all.
     */
    fun joinFallbackPrefix(ssid: String): String? {
        val upper = ssid.trim().uppercase(Locale.ROOT)
        if (!isNikonZAccessPoint(upper)) return null
        return when {
            upper.startsWith(ZR_PREFIX) -> ZR_PREFIX
            upper.startsWith("NIKON_Z") -> "NIKON_Z"
            else -> null
        }
    }

    /** Whether a scanned SSID answers a join for [requested]: the same name, or its Nikon model prefix. */
    fun scanMatches(scanned: String, requested: String): Boolean {
        if (scanned.equals(requested, ignoreCase = true)) return true
        val prefix = joinFallbackPrefix(requested) ?: return false
        return scanned.startsWith(prefix, ignoreCase = true)
    }
}

/** Saved and discovered host keys and the dial rule (Swift `CameraDiscovery`, `PTPIPPairedHosts`). */
object NikonHosts {
    /** A camera access-point setup with no learned address yet: never dialled, rediscovered after join. */
    const val PENDING_ACCESS_POINT_HOST_PREFIX: String = "ap:"

    /** A USB-attached camera's host key: there is no address. */
    const val USB_HOST_KEY_PREFIX: String = "usb:"

    /** The stable key of a host: trimmed and lower-cased; null when empty. */
    fun normalizedHost(host: String): String? = host.trim().lowercase(Locale.ROOT).takeIf(String::isNotEmpty)

    fun pendingAccessPointHostKey(ssid: String?): String {
        val trimmed = ssid?.trim().orEmpty()
        return PENDING_ACCESS_POINT_HOST_PREFIX + trimmed.ifEmpty { "pending" }
    }

    fun isAccessPointHostKey(host: String): Boolean = host.startsWith(PENDING_ACCESS_POINT_HOST_PREFIX)

    fun isUsbHostKey(host: String): Boolean = host.startsWith(USB_HOST_KEY_PREFIX)

    /** Whether a saved or candidate host is ever opened as a TCP peer: a numeric IPv4 address. */
    fun isDialableHost(host: String): Boolean {
        val normalized = normalizedHost(host) ?: return false
        if (isUsbHostKey(normalized) || isAccessPointHostKey(normalized)) return false
        return ipv4Octets(normalized) != null
    }

    /** RFC 1918, 10/8 included: what discovery scans and what a resolved camera may be. */
    fun isPrivateIPv4(address: String): Boolean {
        val octets = ipv4Octets(address) ?: return false
        return octets[0] == 10 || (octets[0] == 172 && octets[1] in 16..31) || (octets[0] == 192 && octets[1] == 168)
    }

    /**
     * Interface name prefixes that never carry a camera: cellular data, VPN and tunnel links, and
     * Apple's peer-to-peer links (Swift `CameraDiscovery.nonCameraInterfacePrefixes`). Carriers
     * hand out private 10/8 addresses on cellular, so a private address alone swept the cellular
     * /24 (hardware pass 2026-10-25).
     */
    private val NON_CAMERA_INTERFACE_PREFIXES: List<String> =
        listOf("pdp_ip", "rmnet", "ccmni", "wwan", "v4-", "clat", "utun", "tun", "ipsec", "ppp", "llw", "awdl", "anpi")

    /**
     * Whether discovery scans from this interface: a private address on an interface that can
     * reach a camera; an empty name is judged by the address alone (Swift
     * `CameraDiscovery.isSupportedScanInterface`).
     */
    fun isScanInterface(name: String, address: String): Boolean {
        if (!isPrivateIPv4(address)) return false
        val lowered = name.trim().lowercase(Locale.ROOT)
        return NON_CAMERA_INTERFACE_PREFIXES.none { lowered.startsWith(it) }
    }

    /** The `a.b.c` /24 base of an IPv4 address, else null. */
    fun subnetBase(address: String): String? = ipv4Octets(address)?.take(3)?.joinToString(".")

    /** Swift's parse: dot-separated, empty parts skipped, four integers in 0..255. */
    private fun ipv4Octets(address: String): List<Int>? {
        val parts = address.split('.').filter(String::isNotEmpty)
        if (parts.size != 4) return null
        val octets = parts.mapNotNull(String::toIntOrNull)
        return octets.takeIf { it.size == 4 && it.all { octet -> octet in 0..255 } }
    }
}

/** Whether an infrastructure (same-LAN Wi-Fi) search may run sockets (Swift `InfrastructurePreflight`). */
sealed interface InfrastructurePreflight {
    /** At least one scannable IPv4 interface; the search may proceed. */
    data class Ready(val subnets: List<String>) : InfrastructurePreflight

    /** No private IPv4 interface is up: Wi-Fi off, mobile data only, or no link. */
    data object NoScannableInterface : InfrastructurePreflight

    /** The OS withholds local-network access; LAN sockets will fail or time out. */
    data object LocalNetworkDenied : InfrastructurePreflight
}

/** Why a completed infrastructure search found no usable camera (Swift `InfrastructureMissReason`). */
sealed interface InfrastructureMissReason {
    data object LocalNetworkDenied : InfrastructureMissReason

    data object NoScannableInterface : InfrastructureMissReason

    /** The phone is still on the body's own access point: an infrastructure setup can never fulfil. */
    data object OnCameraAccessPoint : InfrastructureMissReason

    /** Almost no on-link activity: wrong network, or clients kept apart from each other. */
    data object NetworkUnreachable : InfrastructureMissReason

    /** Hosts answer on the subnet, but nothing accepts PTP-IP. */
    data object HostsVisibleNoPtp : InfrastructureMissReason

    /** The search budget ran out without a camera and without a stronger diagnosis. */
    data object CameraNotFound : InfrastructureMissReason

    /** Another device holds the only known body. */
    data class HeldByOtherDevice(val holder: String) : InfrastructureMissReason
}

/** Counts from one occupancy pass: the inputs classification needs (Swift `InfrastructureSweepTally`). */
data class InfrastructureSweepTally(
    val openCount: Int = 0,
    val occupiedCount: Int = 0,
    val timeoutCount: Int = 0,
    val refusedCount: Int = 0,
    val noRouteCount: Int = 0,
    val deniedCount: Int = 0,
    val otherCount: Int = 0,
    val hostsProbed: Int = 0,
    val occupiedHosts: List<String> = emptyList(),
    val openHosts: List<String> = emptyList(),
) {
    /**
     * Another pass merged in, keeping the union of what each saw: a body waking mid-search answers
     * on pass two and not pass one, and classification must see both.
     */
    fun merging(other: InfrastructureSweepTally): InfrastructureSweepTally =
        InfrastructureSweepTally(
            openCount = maxOf(openCount, other.openCount),
            occupiedCount = maxOf(occupiedCount, other.occupiedCount),
            timeoutCount = maxOf(timeoutCount, other.timeoutCount),
            refusedCount = maxOf(refusedCount, other.refusedCount),
            noRouteCount = maxOf(noRouteCount, other.noRouteCount),
            deniedCount = maxOf(deniedCount, other.deniedCount),
            otherCount = maxOf(otherCount, other.otherCount),
            hostsProbed = maxOf(hostsProbed, other.hostsProbed),
            occupiedHosts = (occupiedHosts + other.occupiedHosts).distinct().sorted(),
            openHosts = (openHosts + other.openHosts).distinct().sorted(),
        )

    companion object {
        /** A tally of per-host verdicts; exhaustive, so a new verdict cannot be forgotten here. */
        fun from(verdicts: Map<String, HostProbeVerdict>): InfrastructureSweepTally {
            var open = 0
            var refused = 0
            var timeout = 0
            var noRoute = 0
            var denied = 0
            var other = 0
            for (verdict in verdicts.values) {
                when (verdict) {
                    HostProbeVerdict.OPEN -> open += 1
                    HostProbeVerdict.REFUSED -> refused += 1
                    HostProbeVerdict.TIMEOUT -> timeout += 1
                    HostProbeVerdict.NO_ROUTE, HostProbeVerdict.NO_NETWORK -> noRoute += 1
                    HostProbeVerdict.DENIED -> denied += 1
                    HostProbeVerdict.UNREACHABLE_OTHER -> other += 1
                }
            }
            val occupiedHosts = verdicts.filterValues { it.isOccupied }.keys.sorted()
            return InfrastructureSweepTally(
                openCount = open,
                occupiedCount = occupiedHosts.size,
                timeoutCount = timeout,
                refusedCount = refused,
                noRouteCount = noRoute,
                deniedCount = denied,
                otherCount = other,
                hostsProbed = verdicts.size,
                occupiedHosts = occupiedHosts,
                openHosts = verdicts.filterValues { it == HostProbeVerdict.OPEN }.keys.sorted(),
            )
        }
    }
}

/** What an empty infrastructure search means (Swift `InfrastructureDiscovery.classifyMiss`). */
object InfrastructureDiscovery {
    fun classifyMiss(
        preflight: InfrastructurePreflight,
        onCameraAccessPoint: Boolean,
        tally: InfrastructureSweepTally?,
        heldHolderName: String? = null,
    ): InfrastructureMissReason {
        if (preflight is InfrastructurePreflight.LocalNetworkDenied) return InfrastructureMissReason.LocalNetworkDenied
        if (preflight is InfrastructurePreflight.NoScannableInterface) return InfrastructureMissReason.NoScannableInterface
        if (onCameraAccessPoint) return InfrastructureMissReason.OnCameraAccessPoint
        if (!heldHolderName.isNullOrEmpty()) return InfrastructureMissReason.HeldByOtherDevice(heldHolderName)
        if (tally == null || tally.hostsProbed <= 0) return InfrastructureMissReason.CameraNotFound
        // Permission or a total blackhole: nothing reachable and the OS refused dials.
        if (tally.deniedCount > 0 && tally.occupiedCount == 0 && tally.openCount == 0) {
            return InfrastructureMissReason.LocalNetworkDenied
        }
        if (tally.occupiedCount == 0 && tally.openCount == 0) {
            // All timeout or no-route: nothing proves the LAN is live.
            val silent = tally.timeoutCount + tally.noRouteCount
            return if (silent >= maxOf(1, tally.hostsProbed / 2)) {
                InfrastructureMissReason.NetworkUnreachable
            } else {
                InfrastructureMissReason.CameraNotFound
            }
        }
        // The LAN is live (hosts refuse or answer) but nothing speaks PTP-IP.
        if (tally.openCount == 0 && tally.occupiedCount > 0) return InfrastructureMissReason.HostsVisibleNoPtp
        return InfrastructureMissReason.CameraNotFound
    }
}
