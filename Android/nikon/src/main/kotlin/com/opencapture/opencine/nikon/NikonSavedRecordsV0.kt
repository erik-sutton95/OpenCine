package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.LegacyCamera
import com.opencapture.opencine.core.LegacyRecordHash
import com.opencapture.opencine.core.LegacySavedCameraCodec
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.core.SavedRoute
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

/**
 * The name that identifies a Nikon body, folded; `null` for a generic or placeholder one. The
 * saved-camera list, nearby matching and the app's records all group and match by it.
 */
fun nikonAssignedName(raw: String): String? {
    val folded = raw.trim().lowercase(Locale.ROOT)
    if (folded.isEmpty() || folded in GENERIC_NAMES || folded.startsWith("camera ")) return null
    return folded
}

private val GENERIC_NAMES = setOf("camera", "nikon camera", "nikon zr", "nikon corporation zr", "ptp-ip camera")

/**
 * The saved setups OpenZCine's Android app wrote before the saved-camera document: one JSON array,
 * one object per setup (preferences `openzcine.saved-cameras` / `records-json`). Keys: `host`,
 * `camera-name`, `transport` (`camera-access-point`, `phone-hotspot`, `infrastructure`, `usb-c`),
 * `last-seen-at` (epoch ms), `wifi-ssid`, `custom-name`, `profile-id`, `network-name`,
 * `setup-name`, `stream-preset`, `quality-bias`. Swift's `NikonSavedRecordsV0` reads the iOS
 * records, which carry a serial; these do not.
 *
 * Mapping: records of one body group by their assigned camera name ([nikonAssignedName]); a
 * generic name is its own camera. Camera id `name:<folded name>`, else
 * the record's profile id. One route per record, most recently seen first (the most recent is
 * preferred), keyed by profile id and transport. `setup-name` -> route title; a record's
 * `custom-name` -> camera name; `wifi-ssid` (access point) or `network-name` (Wi-Fi) -> route
 * network; the other fields ride in the route's extras ([Extra]).
 *
 * The app keeps writing these records with its own save rules ([SavedCameraRecords], through
 * [encode]; [decode] reads them back). A patch edits only what the shared flow changes: a renamed
 * camera (on every record of the body), setup names, and removed cameras and setups. A document
 * route with no record is appended from its extras. Unknown fields and undecodable records are
 * kept.
 */
class NikonSavedRecordsV0 : LegacySavedCameraCodec {
    /** Route extras: the record fields the document has no field for. */
    object Extra {
        const val HOST = "host"
        const val CAMERA_NAME = "cameraName"
        const val TRANSPORT = "transport"
        const val PROFILE_ID = "profileID"
        const val WIFI_SSID = "wifiSsid"
        const val STREAM_PRESET = "streamPreset"
        const val QUALITY_BIAS = "qualityBias"
    }

    override val heldExtras: Set<String> = emptySet()
    override val holdsRouteTitles: Boolean = true

    /** One stored element that decodes as a record. */
    internal class Record(val index: Int, val json: JSONObject) {
        val host: String = json.optString("host").trim()
        val cameraName: String = json.optString("camera-name")
        val transport: String = json.optString("transport")
        val lastSeen: Long? = if (json.has("last-seen-at") && !json.isNull("last-seen-at")) json.optLong("last-seen-at") else null
        val customName: String? = text(json, "custom-name")
        val profileID: String = text(json, "profile-id") ?: host
        val setupName: String? = text(json, "setup-name")
        val kind: RouteKind = kind(transport)
        val network: String? = when (kind) {
            RouteKind.CAMERA_ACCESS_POINT -> text(json, "wifi-ssid")
            // Unnamed: its subnet ("192.168.1.x"), as the app's chips told two router setups apart.
            RouteKind.INFRASTRUCTURE_NETWORK -> text(json, "network-name") ?: subnetLabel(host)
            else -> null
        }
    }

    internal class Placed(val camera: SavedCamera, val members: List<Pair<Record, String>>)

    override fun cameras(data: String): List<LegacyCamera>? {
        val records = read(data) ?: return null
        val keys = mutableSetOf<String>()
        val recordKeys = records.associateWith { unique("${it.profileID}|${it.transport}", keys) }
        return layout(records).map { placed ->
            LegacyCamera(placed.camera, placed.members.associate { (record, _) -> recordKeys.getValue(record) to hash(record.json) })
        }
    }

    override fun patched(data: String?, cameras: List<SavedCamera>): String? {
        val array = if (data == null) JSONArray() else runCatching { JSONArray(data) }.getOrNull() ?: return null
        val placement = HashMap<Int, Pair<String, String>>()
        val legacyNames = HashMap<String, String?>()
        for (placed in layout(records(array))) {
            legacyNames[placed.camera.id] = placed.camera.name
            for ((record, route) in placed.members) placement[record.index] = placed.camera.id to route
        }
        val wanted = LinkedHashMap<String, SavedCamera>()
        for (camera in cameras) wanted.putIfAbsent(camera.id, camera)
        val matched = mutableSetOf<Pair<String, String>>()
        var changed = false
        val out = JSONArray()
        for (index in 0 until array.length()) {
            val element = array.opt(index)
            val place = placement[index]
            if (place == null) {
                out.put(element)
                continue
            }
            val camera = wanted[place.first]
            val route = camera?.routes?.firstOrNull { it.key == place.second }
            if (camera == null || route == null || !matched.add(place)) {
                changed = true
                continue
            }
            val json = element as JSONObject
            if (legacyNames[camera.id] != camera.name && text(json, "custom-name") != camera.name) {
                json.remove("custom-name")
                camera.name?.let { json.put("custom-name", it) }
                changed = true
            }
            if (text(json, "setup-name") != route.title) {
                json.remove("setup-name")
                route.title?.let { json.put("setup-name", it) }
                changed = true
            }
            out.put(json)
        }
        for (camera in cameras) {
            for (route in camera.routes) {
                if ((camera.id to route.key) in matched) continue
                out.put(record(camera, route) ?: continue)
                changed = true
            }
        }
        return if (changed) out.toString() else null
    }

    companion object {
        /** The app's records, canonicalized; an element without a host or not an object is skipped. */
        fun decode(data: String?): List<SavedCameraRecord> {
            val array = data?.let { runCatching { JSONArray(it) }.getOrNull() } ?: return emptyList()
            return SavedCameraRecords.canonicalized((0 until array.length()).mapNotNull { (array.opt(it) as? JSONObject)?.let(::savedRecord) })
        }

        /** [records] canonicalized, as the app writes them: absent values are omitted. */
        fun encode(records: List<SavedCameraRecord>): String {
            val array = JSONArray()
            for (record in SavedCameraRecords.canonicalized(records)) {
                array.put(
                    JSONObject()
                        .put("host", record.host)
                        .put("camera-name", record.cameraName)
                        .put("transport", record.transport.persistedValue)
                        .putOpt("last-seen-at", record.lastSeenAtEpochMillis)
                        .putOpt("wifi-ssid", record.wifiSsid)
                        .putOpt("custom-name", record.customName)
                        .put("profile-id", record.profileID)
                        .putOpt("network-name", record.networkName)
                        .putOpt("setup-name", record.setupName)
                        // By name, never ordinal: the ordinals belong to the Swift bridge.
                        .putOpt("stream-preset", record.streamPreset)
                        .putOpt("quality-bias", record.qualityBias),
                )
            }
            return array.toString()
        }

        private fun savedRecord(json: JSONObject): SavedCameraRecord? {
            val host = json.optString("host").trim().takeIf(String::isNotEmpty) ?: return null
            return SavedCameraRecord(
                host = host,
                cameraName = json.optString("camera-name"),
                transport = SavedCameraTransport.fromPersistedValue(json.optString("transport")),
                lastSeenAtEpochMillis = if (json.isNull("last-seen-at")) null else json.optLong("last-seen-at"),
                wifiSsid = blankless(json, "wifi-ssid"),
                customName = blankless(json, "custom-name"),
                profileID = blankless(json, "profile-id") ?: host,
                networkName = blankless(json, "network-name"),
                setupName = blankless(json, "setup-name"),
                streamPreset = blankless(json, "stream-preset"),
                qualityBias = blankless(json, "quality-bias"),
            )
        }

        private fun blankless(json: JSONObject, key: String): String? = json.optString(key).takeIf(String::isNotBlank)

        /** Each element as the app parses it: an object with a host, else undecodable (kept). */
        internal fun read(data: String): List<Record>? = runCatching { JSONArray(data) }.getOrNull()?.let(::records)

        internal fun records(array: JSONArray): List<Record> = (0 until array.length()).mapNotNull { index ->
            (array.opt(index) as? JSONObject)?.let { Record(index, it) }?.takeIf { it.host.isNotEmpty() }
        }

        /** Cameras in the order of each body's first record; routes most recently seen first. */
        internal fun layout(records: List<Record>): List<Placed> {
            val groups = LinkedHashMap<String, MutableList<Record>>()
            for (record in records) {
                val key = nikonAssignedName(record.cameraName)?.let { "name:$it" } ?: "record:${record.index}"
                groups.getOrPut(key) { mutableListOf() } += record
            }
            // Unique even in data the app never canonicalized: a shared id would drop a setup.
            val ids = mutableSetOf<String>()
            return groups.map { (key, group) ->
                val members = group.sortedByDescending { it.lastSeen ?: Long.MIN_VALUE }
                val keys = mutableSetOf<String>()
                val routes = members.map { record -> route(record, unique("${record.profileID}|${record.transport}", keys)) }
                val first = members.first()
                val camera = SavedCamera(
                    id = unique(if (key.startsWith("name:")) key else first.profileID, ids),
                    integration = NikonOpenCineSession.INTEGRATION,
                    name = members.firstNotNullOfOrNull { it.customName },
                    advertisedName = first.cameraName,
                    model = "",
                    routes = routes,
                    preferredRoute = routes.first().id,
                    lastConnected = members.mapNotNull { it.lastSeen }.maxOrNull(),
                )
                Placed(camera, members.zip(routes.map { it.key }))
            }
        }

        private val TRANSPORTS = mapOf(
            "camera-access-point" to RouteKind.CAMERA_ACCESS_POINT,
            "infrastructure" to RouteKind.INFRASTRUCTURE_NETWORK,
            "phone-hotspot" to RouteKind.PHONE_HOTSPOT,
            "usb-c" to RouteKind.USB,
        )

        /** The app's reading: an unknown or legacy value is the hotspot. */
        internal fun kind(transport: String): RouteKind = TRANSPORTS[transport] ?: RouteKind.PHONE_HOTSPOT

        internal fun transport(kind: RouteKind): String = TRANSPORTS.entries.firstOrNull { it.value == kind }?.key ?: "phone-hotspot"

        private fun route(record: Record, key: String): SavedRoute {
            val extras = linkedMapOf(
                Extra.HOST to record.host, Extra.CAMERA_NAME to record.cameraName, Extra.TRANSPORT to record.transport,
                Extra.PROFILE_ID to record.profileID,
            )
            if (record.kind != RouteKind.CAMERA_ACCESS_POINT) text(record.json, "wifi-ssid")?.let { extras[Extra.WIFI_SSID] = it }
            text(record.json, "stream-preset")?.let { extras[Extra.STREAM_PRESET] = it }
            text(record.json, "quality-bias")?.let { extras[Extra.QUALITY_BIAS] = it }
            return SavedRoute(
                key = key, kind = record.kind, title = record.setupName, network = record.network,
                lastConnected = record.lastSeen, extras = extras,
            )
        }

        /** A record for a document route that has none, in the app's key order; `null` without a host. */
        private fun record(camera: SavedCamera, route: SavedRoute): JSONObject? {
            val host = route.extras[Extra.HOST] ?: return null
            return JSONObject()
                .put("host", host)
                .put("camera-name", route.extras[Extra.CAMERA_NAME] ?: camera.advertisedName)
                .put("transport", route.extras[Extra.TRANSPORT] ?: transport(route.kind))
                .putOpt("last-seen-at", route.lastConnected)
                .putOpt("wifi-ssid", if (route.kind == RouteKind.CAMERA_ACCESS_POINT) route.network else route.extras[Extra.WIFI_SSID])
                .putOpt("custom-name", camera.name)
                .put("profile-id", route.extras[Extra.PROFILE_ID] ?: host)
                .putOpt("network-name", route.network.takeIf { route.kind == RouteKind.INFRASTRUCTURE_NETWORK && it != subnetLabel(host) })
                .putOpt("setup-name", route.title)
                .putOpt("stream-preset", route.extras[Extra.STREAM_PRESET])
                .putOpt("quality-bias", route.extras[Extra.QUALITY_BIAS])
        }

        private fun unique(key: String, keys: MutableSet<String>): String {
            var candidate = key
            var suffix = 1
            while (!keys.add(candidate)) candidate = "$key#${++suffix}"
            return candidate
        }

        /** The subnet label an unnamed Wi-Fi route carries (Swift `CameraDiscovery.subnetBase` + ".x"). */
        internal fun subnetLabel(host: String): String? = NikonHosts.subnetBase(host)?.plus(".x")

        internal fun text(json: JSONObject, key: String): String? =
            if (json.isNull(key)) null else json.optString(key).trim().takeIf { it.isNotEmpty() }

        internal fun hash(json: JSONObject): String = LegacyRecordHash.fnv1a(canonical(json))

        private fun canonical(value: Any?): String = when (value) {
            null, JSONObject.NULL -> "null"
            is JSONObject -> value.keys().asSequence().sorted().joinToString(",", "{", "}") { JSONObject.quote(it) + ":" + canonical(value.get(it)) }
            is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canonical(value.get(it)) }
            is String -> JSONObject.quote(value)
            is Number -> JSONObject.numberToString(value)
            else -> value.toString()
        }
    }
}
