package com.opencapture.opencine.nikon

import java.util.Locale

/**
 * The network route used when this camera was last paired (Swift `CameraPath.Kind`).
 *
 * Camera-access-point records need Android to rejoin the remembered camera network before
 * reconnecting. Phone-hotspot records must never trigger a phone-side Wi-Fi join: the camera joins
 * the phone instead.
 */
enum class SavedCameraTransport(
    /** The record's `transport` value ([NikonSavedRecordsV0]). */
    val persistedValue: String,
    /** Operator-facing label for the saved connection topology. */
    val displayName: String,
) {
    /** The phone connects to the camera's own Wi-Fi access point. */
    CAMERA_ACCESS_POINT("camera-access-point", "Camera access point"),

    /** The camera connects to the phone's Wi-Fi hotspot. */
    PHONE_HOTSPOT("phone-hotspot", "Phone hotspot"),

    /**
     * Both devices on somebody's network: a set router, house Wi-Fi. Like [PHONE_HOTSPOT] the app
     * joins and hosts nothing; the case exists so the operator's Router choice survives
     * persistence instead of collapsing into "hotspot".
     */
    INFRASTRUCTURE("infrastructure", "Wi-Fi"),

    /** A physically attached and permissioned USB PTP camera. */
    USB_C("usb-c", "USB-C");

    companion object {
        // Unknown and legacy values land on PHONE_HOTSPOT: behaviorally identical for reconnect
        // (passive discovery), and every record saved before INFRASTRUCTURE existed carries the
        // collapsed value anyway.
        fun fromPersistedValue(value: String?): SavedCameraTransport =
            entries.firstOrNull { it.persistedValue == value } ?: PHONE_HOTSPOT
    }
}

/**
 * A durable, non-secret Nikon camera setup as OpenZCine's Android app stores it
 * ([NikonSavedRecordsV0]): the Android twin of Swift `PTPIPSavedCameraRecord`, without a serial.
 *
 * Wi-Fi keys stay in the app's Keystore-encrypted credential store. USB records store a
 * privacy-safe digest rather than a raw hardware serial.
 */
data class SavedCameraRecord(
    /** PTP-IP host or privacy-safe USB host digest, normalized to a stable lower-case key. */
    val host: String,
    /** Camera-reported name used when no operator nickname exists. */
    val cameraName: String,
    /** The pairing topology that owns reconnection. */
    val transport: SavedCameraTransport,
    /** Epoch milliseconds when this host last completed a connection, if known. */
    val lastSeenAtEpochMillis: Long?,
    /** Camera AP SSID; never a passphrase. Present only for AP records. */
    val wifiSsid: String?,
    /** Optional operator-facing nickname. */
    val customName: String? = null,
    /**
     * Durable saved-profile identity. Legacy records default to their original host, then retain
     * that value when a dynamic hotspot address changes.
     */
    val profileID: String = host,
    /**
     * The Wi-Fi network an INFRASTRUCTURE setup lives on, when the operator let the app read it:
     * what separates a camera's studio router from its home one. Never the address (a DHCP move
     * merges on purpose). Null when unreadable, and an unnamed network joins whatever router setup
     * is already there.
     */
    val networkName: String? = null,
    /**
     * The operator's own name for THIS setup ("Studio", "Van"). Distinct from [customName], which
     * names the CAMERA: naming one of a body's setups must not rename the body.
     */
    val setupName: String? = null,
    /**
     * The stream preset the camera is asked to send on this setup, by its stored name (the app's
     * `LiveViewStreamPreset`); `null` means never chosen here, which is not the same as a value.
     * Per setup, because the constraint belongs to the path.
     */
    val streamPreset: String? = null,
    /** The compression grade this setup runs at, by its stored name; `null` means never chosen here. */
    val qualityBias: String? = null,
) {
    /** Stable profile identity. */
    val id: String
        get() = profileID

    /** Operator-facing name, preferring a deliberate nickname. */
    val displayTitle: String
        get() = customName?.trim()?.takeIf(String::isNotEmpty) ?: cameraName
}

/**
 * The saved-setup rules of Swift `PTPIPSavedCameraRecords` over the Android record: a record IS
 * one camera setup, keyed by (camera, path kind), and duplicate discovery results and stale
 * hotspot addresses never multiply visible cards. `Fixtures/nikon-setup-vectors.tsv` pins both
 * shells to the same answers.
 */
object SavedCameraRecords {
    /**
     * A camera-AP setup never invents a global IP: a dialable host stays as the last learned
     * address; anything else becomes a pending key that rediscovers after the join.
     */
    fun pinnedToAccessPoint(record: SavedCameraRecord): SavedCameraRecord {
        if (NikonHosts.isDialableHost(record.host)) return record
        val key = NikonHosts.pendingAccessPointHostKey(record.wifiSsid)
        return record.copy(host = key, profileID = key)
    }

    /** Normalized, deduplicated records in their original card order. */
    fun canonicalized(records: List<SavedCameraRecord>): List<SavedCameraRecord> {
        val output = mutableListOf<SavedCameraRecord>()
        for (raw in records) {
            // Normalize, then pin, then dedupe: the pin compares a trimmed host.
            val normalized = normalized(raw)
                ?.let { if (it.transport == SavedCameraTransport.CAMERA_ACCESS_POINT) pinnedToAccessPoint(it) else it }
                ?: continue
            val existingIndex = output.indexOfFirst { describesSameSetup(it, normalized) }
            if (existingIndex < 0) output += normalized else output[existingIndex] = preferred(output[existingIndex], normalized)
        }
        return output
    }

    /**
     * Adds or refreshes a profile after a successful connection. An existing nickname, remembered
     * AP SSID and stream settings survive a dynamic-host refresh. [networkName] is ignored on every
     * transport but infrastructure, which is the only one told apart by its network.
     */
    fun upserting(
        host: String,
        cameraName: String,
        transport: SavedCameraTransport,
        lastSeenAtEpochMillis: Long?,
        wifiSsid: String?,
        records: List<SavedCameraRecord>,
        networkName: String? = null,
    ): List<SavedCameraRecord> {
        val candidate =
            SavedCameraRecord(
                host = host,
                cameraName = cameraName,
                transport = transport,
                lastSeenAtEpochMillis = lastSeenAtEpochMillis,
                wifiSsid = wifiSsid,
                networkName = networkName.takeIf { transport == SavedCameraTransport.INFRASTRUCTURE },
            )
        return canonicalized(records + candidate)
    }

    /**
     * The setup an [upserting] ADDED, or null when it refreshed one that was already there. The
     * pairing wizard saves before the body confirms, so an abandoned pairing takes back only the
     * row it created (Swift `pairingCreatedRecordHost`). Compared by profile id and transport: a
     * refreshed row keeps its id ([preferred]), while a DHCP move changes the address.
     */
    fun createdSetup(before: List<SavedCameraRecord>, after: List<SavedCameraRecord>): SavedCameraRecord? {
        // Two paths of one camera can share an id: both fall back to the host.
        val existing = canonicalized(before).map { it.id to it.transport }.toSet()
        return after.firstOrNull { (it.id to it.transport) !in existing }
    }

    /**
     * Records the stream settings chosen while connected to ONE setup, keyed by (host, transport):
     * one body's access-point and router setups share an address. A `null` argument leaves that
     * setting untouched. Swift `updatingStreamSettings`.
     */
    fun updatingStreamSettings(
        host: String,
        transport: SavedCameraTransport,
        streamPreset: String?,
        qualityBias: String?,
        records: List<SavedCameraRecord>,
    ): List<SavedCameraRecord> {
        val normalizedHost = NikonHosts.normalizedHost(host) ?: return canonicalized(records)
        return canonicalized(records).map { record ->
            if (record.host != normalizedHost || record.transport != transport) {
                record
            } else {
                record.copy(streamPreset = streamPreset ?: record.streamPreset, qualityBias = qualityBias ?: record.qualityBias)
            }
        }
    }

    /**
     * Removes the profile at [host]. [transport] narrows the removal to ONE path of the camera
     * (taking back an abandoned pairing); null forgets every path, which is the operator's Forget.
     * Wi-Fi credentials stay private to their store.
     */
    fun removing(
        host: String,
        cameraName: String? = null,
        records: List<SavedCameraRecord>,
        transport: SavedCameraTransport? = null,
    ): List<SavedCameraRecord> {
        val normalizedHost = NikonHosts.normalizedHost(host) ?: return canonicalized(records)
        return canonicalized(records).filterNot {
            it.host == normalizedHost &&
                (transport == null || it.transport == transport) &&
                // Two bodies legitimately share an address (camera-AP): the name narrows the
                // removal to the one the operator forgot.
                (cameraName.isNullOrBlank() || namesCompatible(it.cameraName, cameraName))
        }
    }

    /**
     * Whether [host] sits on a live hotspot subnet of this device ([phoneHotspotSubnetBases]).
     * Empty bases mean the hotspot is down: there is no global hotspot range to assume.
     */
    fun isPhoneHotspotHost(host: String, hotspotSubnetBases: Collection<String> = emptyList()): Boolean {
        if (hotspotSubnetBases.isEmpty()) return false
        return NikonHosts.subnetBase(host.trim()) in hotspotSubnetBases
    }

    /**
     * This device's own Wi-Fi hotspot /24 bases, keyed on the INTERFACE rather than an address
     * range: Android's tether subnet is an OEM choice. Twin of iOS
     * `NativeNetworkInterfaceSnapshot.hotspotSubnetBases()`. Wi-Fi only: a camera cannot join USB
     * or Bluetooth tethering.
     */
    fun phoneHotspotSubnetBases(interfaces: List<NikonLocalInterface>): Set<String> =
        interfaces.filter { isHotspotInterfaceName(it.name) }.mapNotNull { NikonHosts.subnetBase(it.address) }.toSet()

    fun cameraNamesMatch(lhs: String, rhs: String): Boolean {
        val left = nikonAssignedName(lhs) ?: return false
        val right = nikonAssignedName(rhs) ?: return false
        return left == right
    }

    /**
     * `ap*`, `softap*` and `swlan*` are the SoftAP names OEMs ship, and `wlan1` is the second
     * radio. `wlan0` is always the station and never matches, so the network the operator is on
     * can never read as this phone's own hotspot.
     */
    private fun isHotspotInterfaceName(name: String): Boolean {
        val folded = name.trim().lowercase(Locale.ROOT)
        return folded == "wlan1" || folded.startsWith("ap") || folded.startsWith("softap") || folded.startsWith("swlan")
    }

    /** Swift `describesSameSetup`: the same camera reached by the same kind of path. */
    private fun describesSameSetup(existing: SavedCameraRecord, candidate: SavedCameraRecord): Boolean {
        // Kind first: one body's access-point and router setups are two rows forever.
        if (existing.transport != candidate.transport) return false
        // Within infrastructure the network is part of the key: the name when both have one,
        // else the subnet (a different router is a different subnet in practice).
        if (existing.transport == SavedCameraTransport.INFRASTRUCTURE) {
            val lhs = existing.networkName
            val rhs = candidate.networkName
            val sameNetwork = if (lhs != null && rhs != null) lhs == rhs else NikonHosts.subnetBase(existing.host) == NikonHosts.subnetBase(candidate.host)
            if (!sameNetwork) return false
        }
        // A shared address is one camera only when the names don't contradict it (#293).
        if (existing.profileID == candidate.profileID || existing.host == candidate.host) {
            return namesCompatible(existing.cameraName, candidate.cameraName)
        }
        // Another address on the same path: the cross-host merge that absorbs a DHCP move.
        return cameraNamesMatch(existing.cameraName, candidate.cameraName)
    }

    /** A generic or placeholder name carries no identity, so it contradicts nothing. */
    private fun namesCompatible(lhs: String, rhs: String): Boolean {
        val left = nikonAssignedName(lhs) ?: return true
        val right = nikonAssignedName(rhs) ?: return true
        return left == right
    }

    /** Swift `preferredRecord`: the newer sighting wins (the candidate on a tie), keeping what only the other knew. */
    private fun preferred(existing: SavedCameraRecord, candidate: SavedCameraRecord): SavedCameraRecord {
        val existingSeen = existing.lastSeenAtEpochMillis
        val candidateSeen = candidate.lastSeenAtEpochMillis
        val candidateIsNewer = existingSeen == null || (candidateSeen != null && candidateSeen >= existingSeen)
        val preferred = if (candidateIsNewer) candidate else existing
        val fallback = if (candidateIsNewer) existing else candidate
        return preferred.copy(
            wifiSsid = preferred.wifiSsid ?: fallback.wifiSsid,
            customName = preferred.customName ?: fallback.customName,
            networkName = preferred.networkName ?: fallback.networkName,
            setupName = preferred.setupName ?: fallback.setupName,
            // Load-bearing: every reconnect upserts a record that knows nothing about stream
            // settings, so without these the choice would survive only until the next connect.
            streamPreset = preferred.streamPreset ?: fallback.streamPreset,
            qualityBias = preferred.qualityBias ?: fallback.qualityBias,
            // The existing card owns reconnect state and any offline-media bucket: a refreshed
            // route must not silently create a new owner.
            profileID = existing.profileID,
        )
    }

    private fun normalized(record: SavedCameraRecord): SavedCameraRecord? {
        val host = NikonHosts.normalizedHost(record.host) ?: return null
        return record.copy(
            host = host,
            profileID = NikonHosts.normalizedHost(record.profileID) ?: host,
            cameraName = record.cameraName.trim().ifEmpty { "Camera $host" },
            wifiSsid = normalizedTag(record.wifiSsid),
            networkName = normalizedTag(record.networkName),
            setupName = normalizedTag(record.setupName),
            customName = normalizedTag(record.customName),
        )
    }

    private fun normalizedTag(value: String?): String? = value?.trim()?.takeIf(String::isNotEmpty)
}
