package com.opencapture.opencine.appkit

import android.content.SharedPreferences
import com.opencapture.opencine.core.CameraDeviceID
import com.opencapture.opencine.core.ConnectionRouteID
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.LegacySavedCameraCodec
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.core.SavedCamerasDocument
import com.opencapture.opencine.core.SavedRoute
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** One stored value in the app's own namespace (a preferences key). */
public interface StoredString {
    public fun read(): String?
    public fun write(value: String)
}

public fun SharedPreferences.stored(key: String): StoredString = object : StoredString {
    override fun read(): String? = getString(key, null)
    override fun write(value: String) {
        edit().putString(key, value).apply()
    }
}

/**
 * The saved cameras of one app (Swift `SavedCamerasStore`): a versioned document plus, while older
 * builds may still run, the legacy records it was migrated from, kept mirrored. Confine it to one
 * thread (the main thread in an app).
 *
 * - [load] merges the legacy records into the document (three-way, per
 *   [SavedCamerasDocument.merge]) and writes only the document; a read never writes legacy.
 * - [save] patches the legacy records first, then writes the document with the new merge base,
 *   so a crash between the two writes is merged back on the next launch.
 * - A document from a newer build is never written: this build runs from legacy.
 * - Credentials and every other per-camera store are never read or written here.
 */
public class SavedCamerasStore(private val document: StoredString, private val legacy: Legacy? = null) {
    public class Legacy(
        public val data: StoredString,
        public val codec: LegacySavedCameraCodec,
        /** The merge-base name of this source in the document. */
        public val source: String,
    )

    public var cameras: List<SavedCamera> = emptyList()
        private set

    /** `false` while the stored document is from a newer build. */
    public var writesDocument: Boolean = true
        private set

    private var current = SavedCamerasDocument()

    public fun load() {
        val stored = document.read()
        val version = stored?.let { runCatching { JSONObject(it).optInt("version", 0) }.getOrNull() }
        if (version != null && version > SavedCamerasDocument.CURRENT_VERSION) {
            writesDocument = false
            current = SavedCamerasDocument()
        } else {
            writesDocument = true
            current = stored?.let { runCatching { DocumentJson.decode(it) }.getOrNull() } ?: SavedCamerasDocument()
        }
        if (legacy != null) {
            legacy.data.read()?.let(legacy.codec::cameras)?.let {
                current = current.merge(it, legacy.source, legacy.codec.heldExtras, legacy.codec.holdsRouteTitles)
            }
        }
        cameras = current.cameras
        if (!writesDocument) return
        val encoded = DocumentJson.encode(current)
        if (encoded != stored) document.write(encoded)
    }

    public fun save(cameras: List<SavedCamera>) {
        current = current.copy(cameras = cameras)
        this.cameras = cameras
        if (legacy != null) {
            legacy.codec.patched(legacy.data.read(), cameras)?.let { patched ->
                legacy.data.write(patched)
                current = current.recordMirror(legacy.codec.cameras(patched).orEmpty(), legacy.source)
            }
        }
        if (writesDocument) document.write(DocumentJson.encode(current))
    }
}

/**
 * The document's JSON, key for key what Swift's `Codable` writes (sorted keys, absent optionals
 * omitted, identifiers as `{"uuid": "<UPPERCASE>"}`, dates as epoch milliseconds).
 */
internal object DocumentJson {
    fun encode(document: SavedCamerasDocument): String = canonical(
        JSONObject()
            .put("version", document.version)
            .put("cameras", JSONArray(document.cameras.map(::camera)))
            .put("legacy", JSONObject().also { all -> document.legacy.forEach { (source, base) -> all.put(source, strings(base)) } }),
    )

    fun decode(raw: String): SavedCamerasDocument {
        val json = JSONObject(raw)
        val legacy = json.optJSONObject("legacy")
        return SavedCamerasDocument(
            version = json.getInt("version"),
            cameras = json.getJSONArray("cameras").objects().map(::camera),
            legacy = legacy?.keyList()?.associateWith { strings(legacy.getJSONObject(it)) }.orEmpty(),
        )
    }

    private fun camera(camera: SavedCamera): JSONObject = JSONObject()
        .put("id", camera.id)
        .put("integration", camera.integration.rawValue)
        .putOpt("device", camera.device?.let {
            JSONObject().put("integration", it.integration.rawValue).put("value", it.value).put("isProvisional", it.isProvisional)
        })
        .putOpt("name", camera.name)
        .put("advertisedName", camera.advertisedName)
        .put("model", camera.model)
        .put("routes", JSONArray(camera.routes.map(::route)))
        .putOpt("preferredRoute", camera.preferredRoute?.let(::id))
        .putOpt("lastConnected", camera.lastConnected)
        .put("extras", strings(camera.extras))

    private fun camera(json: JSONObject): SavedCamera = SavedCamera(
        id = json.getString("id"),
        integration = IntegrationID(json.getString("integration")),
        device = json.optJSONObject("device")?.let {
            CameraDeviceID.restored(IntegrationID(it.getString("integration")), it.getString("value"), it.getBoolean("isProvisional"))
        },
        name = json.optStringOrNull("name"),
        advertisedName = json.getString("advertisedName"),
        model = json.getString("model"),
        routes = json.getJSONArray("routes").objects().map(::route),
        preferredRoute = json.optJSONObject("preferredRoute")?.let(::id),
        lastConnected = json.optLongOrNull("lastConnected"),
        extras = strings(json.optJSONObject("extras")),
    )

    private fun route(route: SavedRoute): JSONObject = JSONObject()
        .put("id", id(route.id))
        .put("key", route.key)
        .put("kind", route.kind.rawValue)
        .putOpt("title", route.title)
        .putOpt("network", route.network)
        .put("bluetooth", route.bluetooth)
        .putOpt("lastConnected", route.lastConnected)
        .put("extras", strings(route.extras))

    private fun route(json: JSONObject): SavedRoute = SavedRoute(
        id = id(json.getJSONObject("id")),
        key = json.getString("key"),
        kind = RouteKind.of(json.getString("kind")) ?: error("unknown route kind ${json.getString("kind")}"),
        title = json.optStringOrNull("title"),
        network = json.optStringOrNull("network"),
        bluetooth = json.getBoolean("bluetooth"),
        lastConnected = json.optLongOrNull("lastConnected"),
        extras = strings(json.optJSONObject("extras")),
    )

    private fun id(id: ConnectionRouteID): JSONObject = JSONObject().put("uuid", id.uuid.toString().uppercase())

    private fun id(json: JSONObject): ConnectionRouteID = ConnectionRouteID(UUID.fromString(json.getString("uuid")))

    private fun strings(map: Map<String, String>): JSONObject = JSONObject().also { json -> map.forEach { (k, v) -> json.put(k, v) } }

    private fun strings(json: JSONObject?): Map<String, String> =
        json?.keyList()?.associateWith { json.getString(it) }.orEmpty()
}

internal fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }

internal fun JSONObject.keyList(): List<String> = keys().asSequence().toList()

internal fun JSONObject.optStringOrNull(key: String): String? = if (isNull(key)) null else optString(key)

internal fun JSONObject.optLongOrNull(key: String): Long? = if (isNull(key)) null else (opt(key) as? Number)?.toLong()

/** JSON with sorted keys at every level, so equal values always give equal bytes. */
internal fun canonical(value: Any?): String = when (value) {
    null, JSONObject.NULL -> "null"
    is JSONObject -> value.keyList().sorted().joinToString(",", "{", "}") { JSONObject.quote(it) + ":" + canonical(value.get(it)) }
    is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canonical(value.get(it)) }
    is String -> JSONObject.quote(value)
    is Number -> JSONObject.numberToString(value)
    else -> value.toString()
}
