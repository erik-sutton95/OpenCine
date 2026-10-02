package com.opencapture.opencine.dji

import org.json.JSONObject

/** Model support from the shared core (`MulticamSupport`). Cached per model identity. */
data class MulticamSupportInfo(val appears: Boolean, val preview: Boolean, val missingRoleQueryE0: Boolean)

private val supportCache = HashMap<String, MulticamSupportInfo>()

fun FoundCamera.multicamSupport(): MulticamSupportInfo {
    val key = "${modelId ?: -1}|$name|${model.name}"
    synchronized(supportCache) { supportCache[key]?.let { return it } }
    val request = JSONObject().put("name", model.name.ifEmpty { name })
    modelId?.let { request.put("modelId", it) }
    val raw = if (DjiNative.isAvailable) DjiNative.multicamDecision("support", request.toString()) else null
    val json = raw?.let { runCatching { JSONObject(it) }.getOrNull() }
    val info = MulticamSupportInfo(
        appears = json?.optBoolean("appears") ?: false,
        preview = json?.optBoolean("preview") ?: false,
        missingRoleQueryE0 = json?.optBoolean("missingRoleQueryE0") ?: false,
    )
    synchronized(supportCache) { supportCache[key] = info }
    return info
}

val FoundCamera.appearsInMultiview: Boolean get() = multicamSupport().appears

val FoundCamera.hasMultiviewPreview: Boolean get() = multicamSupport().preview
