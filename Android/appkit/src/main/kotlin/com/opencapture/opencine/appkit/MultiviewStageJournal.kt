package com.opencapture.opencine.appkit

import org.json.JSONArray
import org.json.JSONObject

/**
 * The saved Multiview stage: what an app writes so a relaunch restores the operator's layout and
 * finishes a pending camera network cleanup (Swift twin: `MultiviewStageJournal`).
 *
 * Values, rules and the JSON codec only. Where the stage lives (preferences) stays in the app,
 * which passes its own tile count to [Stage.validated]. The JSON keys are the ones the camera apps
 * already store, so earlier saved stages decode unchanged. Network credentials never belong here.
 */
public object MultiviewStageJournal {
    public data class Camera(
        public val slot: Int,
        public val id: String,
        public val name: String,
        /** The integration's model code. */
        public val modelId: Int? = null,
        /** The integration's identity proof (hex in JSON). */
        public val identity: ByteArray? = null,
        /** A platform address to reconnect by (a Bluetooth address); stored as `bleAddress`. */
        public val deviceAddress: String? = null,
        public val address: String,
        public val experimental: Boolean,
        public val lutEnabled: Boolean,
    ) {
        public override fun equals(other: Any?): Boolean =
            other is Camera && slot == other.slot && id == other.id && name == other.name &&
                modelId == other.modelId && deviceAddress == other.deviceAddress &&
                identity.contentEqualsNullable(other.identity) && address == other.address &&
                experimental == other.experimental && lutEnabled == other.lutEnabled

        public override fun hashCode(): Int = id.hashCode()
    }

    public data class Stage(
        public val version: Int = 1,
        public val ssid: String,
        public val hotspot: Boolean,
        public val layout: String,
        public val focusedIndex: Int,
        public val cameras: List<Camera>,
        public val pendingReset: List<Camera>? = null,
        public val returnedToCameraWiFi: Boolean? = null,
        public val fill: Boolean? = null,
    ) {
        /**
         * The stage when it is safe to restore with [tileCount] tiles, else null. A stage needs a
         * network unless it is only a cleanup ledger (no cameras, something left to reset).
         */
        public fun validated(tileCount: Int): Stage? {
            val cleanup = pendingReset.orEmpty()
            val valid = version == 1 &&
                (ssid.isNotEmpty() || (cameras.isEmpty() && cleanup.isNotEmpty())) &&
                cameras.size <= tileCount &&
                focusedIndex in 0 until tileCount &&
                cameras.map { it.slot }.toSet().size == cameras.size &&
                cameras.map { it.id }.toSet().size == cameras.size &&
                cleanup.map { it.id }.toSet().size == cleanup.size &&
                cleanup.all { it.name.isNotEmpty() } &&
                cameras.all { it.slot in 0 until tileCount && it.name.isNotEmpty() }
            return if (valid) this else null
        }
    }

    /** [pending] with each of [including] replacing the entry of the same id, or appended when new. */
    public fun cleanupTargets(pending: List<Camera>, including: List<Camera>): List<Camera> {
        val result = pending.toMutableList()
        for (camera in including) {
            val index = result.indexOfFirst { it.id == camera.id }
            if (index >= 0) result[index] = camera else result += camera
        }
        return result
    }

    public fun encode(stage: Stage): String =
        JSONObject()
            .put("version", stage.version)
            .put("ssid", stage.ssid)
            .put("hotspot", stage.hotspot)
            .put("layout", stage.layout)
            .put("focusedIndex", stage.focusedIndex)
            .put("cameras", JSONArray(stage.cameras.map(::encodeCamera)))
            .apply {
                stage.pendingReset?.let { put("pendingReset", JSONArray(it.map(::encodeCamera))) }
                stage.returnedToCameraWiFi?.let { put("returnedToCameraWiFi", it) }
                stage.fill?.let { put("fill", it) }
            }
            .toString()

    /** The stored stage, or null when [raw] is unreadable. The app applies [Stage.validated]. */
    public fun decode(raw: String): Stage? =
        runCatching {
            val json = JSONObject(raw)
            Stage(
                version = json.getInt("version"),
                ssid = json.getString("ssid"),
                hotspot = json.getBoolean("hotspot"),
                layout = json.getString("layout"),
                focusedIndex = json.getInt("focusedIndex"),
                cameras = cameras(json.getJSONArray("cameras")),
                pendingReset = json.optJSONArray("pendingReset")?.let(::cameras),
                returnedToCameraWiFi = if (json.has("returnedToCameraWiFi")) json.getBoolean("returnedToCameraWiFi") else null,
                fill = if (json.has("fill")) json.getBoolean("fill") else null,
            )
        }.getOrNull()

    private fun cameras(array: JSONArray): List<Camera> =
        (0 until array.length()).map { index ->
            val item = array.getJSONObject(index)
            Camera(
                slot = item.getInt("slot"),
                id = item.getString("id"),
                name = item.getString("name"),
                modelId = if (item.has("modelId")) item.getInt("modelId") else null,
                identity = item.optString("identity").takeIf { it.isNotEmpty() }?.let(::unhex),
                deviceAddress = if (item.has("bleAddress")) item.getString("bleAddress") else null,
                address = item.optString("address"),
                experimental = item.optBoolean("experimental"),
                lutEnabled = item.optBoolean("lutEnabled"),
            )
        }

    private fun encodeCamera(camera: Camera): JSONObject =
        JSONObject()
            .put("slot", camera.slot)
            .put("id", camera.id)
            .put("name", camera.name)
            .put("address", camera.address)
            .put("experimental", camera.experimental)
            .put("lutEnabled", camera.lutEnabled)
            .apply {
                camera.deviceAddress?.let { put("bleAddress", it) }
                camera.modelId?.let { put("modelId", it) }
                camera.identity?.let { put("identity", hex(it)) }
            }

    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 0xFF) }

    private fun unhex(value: String): ByteArray? {
        if (value.length % 2 != 0) return null
        return runCatching {
            ByteArray(value.length / 2) { value.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        }.getOrNull()
    }

    private fun ByteArray?.contentEqualsNullable(other: ByteArray?): Boolean =
        if (this == null) other == null else other != null && contentEquals(other)
}
