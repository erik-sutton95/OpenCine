package com.opencapture.opencine.core

/** One saved way to reach a camera (a "setup"). Dates are epoch milliseconds. */
public data class SavedRoute(
    /** Minted once and kept in the saved document. */
    public val id: ConnectionRouteID = ConnectionRouteID(),
    /** Codec-stable identity within the camera, for example `ap`, `wifi`, `hotspot`. */
    public val key: String,
    public val kind: RouteKind,
    /** The operator's setup name; `null` uses the shell's title for the kind. */
    public val title: String? = null,
    /** Network name (SSID) or interface name. Never a secret. */
    public val network: String? = null,
    /** Needs Bluetooth commissioning before the route comes up. */
    public val bluetooth: Boolean = false,
    public val lastConnected: Long? = null,
    /** Integration-owned values, kept verbatim. */
    public val extras: Map<String, String> = emptyMap(),
)

/** One saved camera with its routes. */
public data class SavedCamera(
    /**
     * Stable local key. A migrated camera keeps its legacy record id verbatim, so credentials,
     * media and calibration keyed by it keep working.
     */
    public val id: String,
    public val integration: IntegrationID,
    /** Durable identity when known (a serial); never derived from a host or a name. */
    public val device: CameraDeviceID? = null,
    /** The operator's rename. */
    public val name: String? = null,
    public val advertisedName: String,
    public val model: String,
    /** In chip order. */
    public val routes: List<SavedRoute> = emptyList(),
    public val preferredRoute: ConnectionRouteID? = null,
    public val lastConnected: Long? = null,
    /** Integration-owned values, kept verbatim. */
    public val extras: Map<String, String> = emptyMap(),
) {
    /** The rename, else the advertised name. */
    public val displayName: String get() = name ?: advertisedName
}

/**
 * The saved cameras of one app, as stored. A reader that finds a [version] above
 * [CURRENT_VERSION] never writes the document.
 */
public data class SavedCamerasDocument(
    public val version: Int = CURRENT_VERSION,
    public val cameras: List<SavedCamera> = emptyList(),
    /** Merge base per legacy source: record key -> hash of that record as last imported or mirrored. */
    public val legacy: Map<String, Map<String, String>> = emptyMap(),
) {
    /**
     * Three-way merge of one legacy source (Swift `merge(_:from:heldExtras:holdsRouteTitles:)`). Base:
     * `legacy[source]`; theirs: [records]; ours: this document. A camera whose records changed
     * since the base takes the fields legacy holds and keeps the document's own (route ids, a
     * learned device, titles the codec does not hold, and extras). An unchanged camera keeps the
     * document version except legacy-owned titles, which also repair fingerprints recorded by older stores. A
     * camera legacy no longer lists is removed, unless nothing was ever mirrored from this source.
     * New legacy cameras are added. The base becomes [records].
     */
    public fun merge(records: List<LegacyCamera>, source: String, heldExtras: Set<String>, holdsRouteTitles: Boolean = false): SavedCamerasDocument {
        val base = legacy[source].orEmpty()
        val theirs = LinkedHashMap<String, LegacyCamera>()
        for (record in records) theirs.putIfAbsent(record.camera.id, record)
        // A record gone since the base: with one record per setup, the camera's other records
        // can be unchanged, so a camera whose routes legacy no longer lists changed too.
        val current = records.flatMap { it.records.keys }.toSet()
        val removedSome = base.keys.any { it !in current }
        val merged = mutableListOf<SavedCamera>()
        for (ours in cameras) {
            val record = theirs.remove(ours.id)
            if (record == null) {
                if (base.isEmpty()) merged += ours
                continue
            }
            val lostRoute = removedSome && !record.camera.routes.map { it.key }.containsAll(ours.routes.map { it.key })
            val changed = lostRoute || record.records.any { (key, hash) -> base[key] != hash }
            merged += when {
                changed -> overlay(record.camera, ours, heldExtras, holdsRouteTitles)
                holdsRouteTitles -> ours.copy(routes = ours.routes.map { route ->
                    val legacyRoute = record.camera.routes.firstOrNull { it.key == route.key }
                    if (legacyRoute != null) route.copy(title = legacyRoute.title) else route
                })
                else -> ours
            }
        }
        merged += theirs.values.map { it.camera }
        return copy(cameras = merged).recordMirror(records, source)
    }

    /** The document with the merge base of [source] set to these records (after reading or writing it). */
    public fun recordMirror(records: List<LegacyCamera>, source: String): SavedCamerasDocument {
        val base = LinkedHashMap<String, String>()
        for (record in records) for ((key, hash) in record.records) base.putIfAbsent(key, hash)
        return copy(legacy = legacy + (source to base))
    }

    public companion object {
        public const val CURRENT_VERSION: Int = 1

        internal fun overlay(theirs: SavedCamera, ours: SavedCamera, heldExtras: Set<String>, holdsRouteTitles: Boolean = false): SavedCamera {
            val routes = theirs.routes.map { route ->
                val mine = ours.routes.firstOrNull { it.key == route.key } ?: return@map route
                route.copy(
                    id = mine.id,
                    title = if (holdsRouteTitles) route.title else route.title ?: mine.title,
                    lastConnected = route.lastConnected ?: mine.lastConnected,
                    extras = mine.extras + route.extras,
                )
            }
            val preferredKey = theirs.routes.firstOrNull { it.id == theirs.preferredRoute }?.key
            return theirs.copy(
                device = theirs.device ?: ours.device,
                routes = routes,
                preferredRoute = routes.firstOrNull { it.key == preferredKey }?.id,
                extras = ours.extras.filterKeys { it !in heldExtras } + theirs.extras,
            )
        }
    }
}

/** One camera as a legacy saved-camera format describes it, with the records it came from. */
public data class LegacyCamera(
    public val camera: SavedCamera,
    /** Record key -> hash of the record as stored. */
    public val records: Map<String, String>,
)

/**
 * A saved-camera format an app wrote before the document. The store reads it on every launch and
 * keeps it mirrored, so an older build still sees current data (add, migrate, remove).
 */
public interface LegacySavedCameraCodec {
    /** Integration extras the legacy records hold. They come from legacy only, absence included. */
    public val heldExtras: Set<String>

    /** Whether legacy records own setup titles, including an explicitly cleared title. */
    public val holdsRouteTitles: Boolean get() = false

    /**
     * Every decodable camera in stored order; undecodable records are skipped. `null` when the
     * data is not readable at all.
     */
    public fun cameras(data: String): List<LegacyCamera>?

    /**
     * [data] (`null`: nothing stored yet) patched to describe [cameras]: changed fields edited in
     * place, forgotten cameras removed, new ones appended, unknown fields and undecodable records
     * kept verbatim. `null` when nothing changes or the data is not readable.
     */
    public fun patched(data: String?, cameras: List<SavedCamera>): String?
}

/** Change detection for legacy records (Swift `LegacyRecordHash`): FNV-1a 64 of the record's sorted-key JSON. */
// ponytail: change detection only, not integrity; a collision merely skips one legacy edit.
public object LegacyRecordHash {
    public fun fnv1a(canonicalJson: String): String {
        var hash = -0x340d631b7bdddcdbL
        for (byte in canonicalJson.toByteArray()) {
            hash = hash xor (byte.toLong() and 0xff)
            hash *= 0x100000001b3L
        }
        return java.lang.Long.toUnsignedString(hash, 16)
    }
}
