package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.ConnectionRouteID
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.LegacyCamera
import com.opencapture.opencine.core.LegacyRecordHash
import com.opencapture.opencine.core.LegacySavedCameraCodec
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.core.SavedRoute
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.roundToLong

/**
 * The per-body saved-camera records apps wrote before the document (Swift `BodyRecordsV0`): one
 * JSON array, one object per body. Fields: `id`, `advertisedName`, `modelName`, optional
 * `modelId` (a number), `lastConnectedAt`, optional `customName`, `lastSSID` (the camera's access
 * point), `wifiSSID`, `hotspotSSID` and `lastSetup` (`cameraWiFi`, `wifi` or `phoneHotspot`).
 *
 * Mapping: routes `ap` (access point, always present), `wifi` (infrastructure) and `hotspot`,
 * each over Bluetooth first; `lastSetup` -> `preferredRoute` (kept verbatim in
 * `extras["lastSetup"]` when its route is gone); `modelId` -> `extras["modelId"]`; `customName`
 * -> `name`. An empty string is absent. A record without an `id` is undecodable.
 */
public class BodyRecordsV0(public val integration: IntegrationID, public val dates: Dates) : LegacySavedCameraCodec {
    public enum class Dates {
        /** Swift `Date`'s default `Codable` form: seconds since 2001-01-01. */
        SECONDS_SINCE_2001,
        EPOCH_MILLISECONDS,
    }

    override val heldExtras: Set<String> = setOf("modelId", "lastSetup")

    private class Setup(val raw: String, val key: String, val kind: RouteKind, val field: String)

    override fun cameras(data: String): List<LegacyCamera>? {
        val array = runCatching { JSONArray(data) }.getOrNull() ?: return null
        return (0 until array.length()).mapNotNull { index ->
            val json = array.opt(index) as? JSONObject ?: return@mapNotNull null
            val camera = camera(json) ?: return@mapNotNull null
            LegacyCamera(camera, mapOf(camera.id to hash(json)))
        }
    }

    override fun patched(data: String?, cameras: List<SavedCamera>): String? {
        val array = if (data == null) JSONArray() else runCatching { JSONArray(data) }.getOrNull() ?: return null
        val wanted = LinkedHashMap<String, SavedCamera>()
        for (camera in cameras) wanted.putIfAbsent(camera.id, camera)
        val written = mutableSetOf<String>()
        var changed = false
        val out = JSONArray()
        for (index in 0 until array.length()) {
            val element = array.opt(index)
            val current = (element as? JSONObject)?.let(::camera)
            if (current == null) {
                out.put(element)
                continue
            }
            val camera = wanted[current.id]
            if (camera == null || !written.add(current.id)) {
                changed = true
                continue
            }
            val json = element as JSONObject
            val now = values(current)
            val next = values(camera)
            for (key in FIELDS) {
                if (now[key] == next[key]) continue
                json.remove(key)
                next[key]?.let { json.put(key, stored(key, it)) }
                changed = true
            }
            out.put(json)
        }
        for (camera in cameras) {
            if (!written.add(camera.id)) continue
            val json = JSONObject().put("id", camera.id)
            for ((key, value) in values(camera)) json.put(key, stored(key, value))
            out.put(json)
            changed = true
        }
        return if (changed) out.toString() else null
    }

    private fun camera(json: JSONObject): SavedCamera? {
        val id = string(json, "id") ?: return null
        val routes = SETUPS.mapNotNull { setup ->
            val network = string(json, setup.field)
            if (setup.key != "ap" && network == null) null else SavedRoute(key = setup.key, kind = setup.kind, network = network, bluetooth = true)
        }
        val extras = LinkedHashMap<String, String>()
        (json.opt("modelId") as? Number)?.let { extras["modelId"] = it.toLong().toString() }
        var preferred: ConnectionRouteID? = null
        string(json, "lastSetup")?.let { lastSetup ->
            val key = SETUPS.firstOrNull { it.raw == lastSetup }?.key
            val route = routes.firstOrNull { it.key == key }
            if (route != null) preferred = route.id else extras["lastSetup"] = lastSetup
        }
        return SavedCamera(
            id = id,
            integration = integration,
            name = string(json, "customName"),
            advertisedName = json.opt("advertisedName") as? String ?: "",
            model = json.opt("modelName") as? String ?: "",
            routes = routes,
            preferredRoute = preferred,
            lastConnected = (json.opt("lastConnectedAt") as? Number)?.let(::milliseconds),
            extras = extras,
        )
    }

    /**
     * The stored fields of a camera, normalized for comparison (dates as epoch milliseconds). A
     * missing key is an absent field; names and `lastConnectedAt` are always present, because
     * older decoders require them.
     */
    private fun values(camera: SavedCamera): Map<String, Any> {
        val values = linkedMapOf<String, Any>(
            "advertisedName" to camera.advertisedName,
            "modelName" to camera.model,
            "lastConnectedAt" to (camera.lastConnected ?: 0L),
        )
        camera.name?.let { values["customName"] = it }
        camera.extras["modelId"]?.toLongOrNull()?.let { values["modelId"] = it }
        for (setup in SETUPS) camera.routes.firstOrNull { it.key == setup.key }?.network?.let { values[setup.field] = it }
        val preferredKey = camera.routes.firstOrNull { it.id == camera.preferredRoute }?.key
        (SETUPS.firstOrNull { it.key == preferredKey }?.raw ?: camera.extras["lastSetup"])?.let { values["lastSetup"] = it }
        return values
    }

    private fun stored(key: String, value: Any): Any {
        if (key != "lastConnectedAt") return value
        val milliseconds = value as Long
        return when (dates) {
            Dates.EPOCH_MILLISECONDS -> milliseconds
            Dates.SECONDS_SINCE_2001 -> milliseconds / 1000.0 - REFERENCE_SECONDS
        }
    }

    private fun milliseconds(number: Number): Long = when (dates) {
        Dates.EPOCH_MILLISECONDS -> number.toLong()
        Dates.SECONDS_SINCE_2001 -> ((number.toDouble() + REFERENCE_SECONDS) * 1000).roundToLong()
    }

    private companion object {
        /** 2001-01-01 in seconds since 1970. */
        const val REFERENCE_SECONDS = 978_307_200.0

        val SETUPS = listOf(
            Setup("cameraWiFi", "ap", RouteKind.CAMERA_ACCESS_POINT, "lastSSID"),
            Setup("wifi", "wifi", RouteKind.INFRASTRUCTURE_NETWORK, "wifiSSID"),
            Setup("phoneHotspot", "hotspot", RouteKind.PHONE_HOTSPOT, "hotspotSSID"),
        )

        val FIELDS = listOf(
            "advertisedName", "modelName", "customName", "lastConnectedAt", "modelId", "lastSSID", "wifiSSID",
            "hotspotSSID", "lastSetup",
        )

        fun string(json: JSONObject, key: String): String? = (json.opt(key) as? String)?.takeIf { it.isNotEmpty() }

        fun hash(json: JSONObject): String = LegacyRecordHash.fnv1a(canonical(json))
    }
}
