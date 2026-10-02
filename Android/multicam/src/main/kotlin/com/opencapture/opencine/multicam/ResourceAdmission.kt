package com.opencapture.opencine.multicam

import com.opencapture.opencine.core.CameraDeviceID
import com.opencapture.opencine.core.MonitorEntryID
import com.opencapture.opencine.core.MulticamQualification
import com.opencapture.opencine.core.MulticamQualificationRefusal
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedRoute

/**
 * A host resource a connection route needs. Integrations declare them; they know how to
 * establish and release the route. Network names and interface identities are opaque,
 * integration-chosen strings.
 */
public sealed interface ResourceClaim {
    /**
     * The phone joins this camera's own access point. The phone has one Wi-Fi association, and
     * the access point serves one camera.
     */
    public data class CameraAccessPoint(public val network: String) : ResourceClaim

    /**
     * Phone and camera share this infrastructure network (router or hotspot). Several cameras
     * may coexist on one; the phone still joins only one.
     */
    public data class InfrastructureNetwork(public val network: String) : ResourceClaim

    /** Exclusive ownership of one USB interface. */
    public data class UsbInterface(public val name: String) : ResourceClaim

    /** Temporary Bluetooth commissioning or provisioning. One device at a time. */
    public data object BluetoothCommissioning : ResourceClaim

    public companion object {
        /**
         * What a saved route claims on the phone. A hotspot is an infrastructure network named
         * `hotspot:<network>`, so it conflicts with any other Wi-Fi. A USB or capture route claims
         * its interface. A route that needs Bluetooth first also claims commissioning.
         */
        public fun claims(route: SavedRoute): List<ResourceClaim> {
            // ponytail: an unknown network or interface is this route's own name, so it never
            // matches another route's; a known name replaces it once the route reports one.
            val name = route.network ?: "route:${route.id.uuid.toString().uppercase()}"
            val claim = when (route.kind) {
                RouteKind.CAMERA_ACCESS_POINT -> CameraAccessPoint(name)
                RouteKind.INFRASTRUCTURE_NETWORK -> InfrastructureNetwork(name)
                RouteKind.PHONE_HOTSPOT -> InfrastructureNetwork("hotspot:$name")
                RouteKind.USB, RouteKind.CAPTURE_DEVICE -> UsbInterface(name)
            }
            // ponytail: commissioning is claimed for the whole entry; split candidate and member
            // requests when a multicam app admits members that commission over Bluetooth.
            return if (route.bluetooth) listOf(claim, BluetoothCommissioning) else listOf(claim)
        }
    }
}

/**
 * What one entry's route needs. Entries of the same device never conflict with each other: a
 * picture entry and a control entry of one camera share its route.
 */
public data class ResourceRequest(
    public val entry: MonitorEntryID,
    public val device: CameraDeviceID?,
    public val claims: List<ResourceClaim>,
    /** Estimates; zero when the route carries no picture. */
    public val bitsPerSecond: Long = 0,
    public val decoders: Int = 0,
) {
    /**
     * The request for one entry on a saved route: its claims, one decoder when it carries the
     * picture, and the caller's bandwidth estimate.
     */
    public constructor(
        entry: MonitorEntryID,
        device: CameraDeviceID?,
        route: SavedRoute,
        picture: Boolean,
        bitsPerSecond: Long = 0,
    ) : this(entry, device, ResourceClaim.claims(route), bitsPerSecond, if (picture) 1 else 0)
}

/**
 * The app's limits. [qualifiedEntries] is the tested product limit (for example four), never an
 * engine constant; `null` means unlimited.
 */
public data class ResourceBudget(
    public val qualifiedEntries: Int?,
    public val bitsPerSecond: Long? = null,
    public val decoders: Int? = null,
)

public sealed interface AdmissionReason {
    public data object QualificationUnknown : AdmissionReason
    public data class IntegrationRefused(public val reason: MulticamQualificationRefusal) : AdmissionReason
    public data class OverQualifiedLimit(public val limit: Int) : AdmissionReason

    /** The candidate needs a different phone Wi-Fi network than this member. */
    public data class WifiNetworkConflict(public val with: MonitorEntryID) : AdmissionReason

    /** Another device already uses this camera access point. */
    public data class AccessPointTaken(public val by: MonitorEntryID) : AdmissionReason
    public data class UsbInterfaceTaken(public val by: MonitorEntryID) : AdmissionReason
    public data class CommissioningInProgress(public val by: MonitorEntryID) : AdmissionReason
    public data class BandwidthExceeded(public val needed: Long, public val limit: Long) : AdmissionReason
    public data class DecodersExceeded(public val needed: Int, public val limit: Int) : AdmissionReason
}

/**
 * Feasibility of adding one route next to the current members, checked before any disruptive
 * transition (joining a network, claiming USB). It describes; it never provisions or releases.
 */
public object ResourceAdmission {
    /**
     * Combines the integration's configuration qualification with the app's resource budget.
     * Unknown qualification blocks admission; this never infers camera observations or sends
     * a command. The resource-only overload remains useful for single connection feasibility.
     */
    public fun reasons(
        candidate: ResourceRequest,
        qualification: MulticamQualification,
        members: List<ResourceRequest>,
        budget: ResourceBudget,
    ): List<AdmissionReason> {
        val qualificationReasons = when (qualification) {
            MulticamQualification.Qualified -> emptyList()
            MulticamQualification.Unknown -> listOf(AdmissionReason.QualificationUnknown)
            is MulticamQualification.Refused -> listOf(AdmissionReason.IntegrationRefused(qualification.reason))
        }
        return qualificationReasons + reasons(candidate, members, budget)
    }

    /** Empty when [candidate] may join. */
    public fun reasons(
        candidate: ResourceRequest,
        members: List<ResourceRequest>,
        budget: ResourceBudget,
    ): List<AdmissionReason> {
        val reasons = mutableListOf<AdmissionReason>()
        val others = members.filter { it.entry != candidate.entry }
        budget.qualifiedEntries?.let { if (others.size + 1 > it) reasons += AdmissionReason.OverQualifiedLimit(it) }
        for (member in others) {
            val sameDevice = candidate.device != null && member.device == candidate.device
            for (mine in candidate.claims) {
                for (theirs in member.claims) {
                    val reason = conflict(mine, theirs, member.entry, sameDevice) ?: continue
                    if (reason !in reasons) reasons += reason
                }
            }
        }
        val all = others + candidate
        val bits = all.sumOf { it.bitsPerSecond }
        budget.bitsPerSecond?.let { if (bits > it) reasons += AdmissionReason.BandwidthExceeded(bits, it) }
        val decoders = all.sumOf { it.decoders }
        budget.decoders?.let { if (decoders > it) reasons += AdmissionReason.DecodersExceeded(decoders, it) }
        return reasons
    }

    private fun conflict(
        mine: ResourceClaim,
        theirs: ResourceClaim,
        member: MonitorEntryID,
        sameDevice: Boolean,
    ): AdmissionReason? {
        val myNetwork = mine.wifiNetwork
        val theirNetwork = theirs.wifiNetwork
        return when {
            mine is ResourceClaim.CameraAccessPoint && theirs is ResourceClaim.CameraAccessPoint -> when {
                mine.network != theirs.network -> AdmissionReason.WifiNetworkConflict(member)
                sameDevice -> null
                else -> AdmissionReason.AccessPointTaken(member)
            }
            myNetwork != null && theirNetwork != null ->
                if (myNetwork == theirNetwork) null else AdmissionReason.WifiNetworkConflict(member)
            mine is ResourceClaim.UsbInterface && theirs is ResourceClaim.UsbInterface ->
                if (mine.name == theirs.name && !sameDevice) AdmissionReason.UsbInterfaceTaken(member) else null
            mine == ResourceClaim.BluetoothCommissioning && theirs == ResourceClaim.BluetoothCommissioning ->
                if (sameDevice) null else AdmissionReason.CommissioningInProgress(member)
            else -> null
        }
    }

    /** The phone Wi-Fi network a claim joins, if any. */
    private val ResourceClaim.wifiNetwork: String?
        get() = when (this) {
            is ResourceClaim.CameraAccessPoint -> network
            is ResourceClaim.InfrastructureNetwork -> network
            is ResourceClaim.UsbInterface, ResourceClaim.BluetoothCommissioning -> null
        }
}
