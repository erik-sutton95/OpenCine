package com.opencapture.opencine.dji

import com.opencapture.opencine.core.MulticamQualification
import com.opencapture.opencine.core.MulticamQualificationRefusal
import com.opencapture.opencine.vocabulary.FoundCamera
import org.json.JSONObject

/** Model support from the shared core (`MulticamSupport`). Cached per model identity. */
data class MulticamSupportInfo(
    val appears: Boolean,
    val preview: Boolean,
    val missingRoleQueryE0: Boolean,
    /** False until the native integration supplies a complete support verdict. */
    val known: Boolean = true,
) {
    /** The captured-preview policy, with the operator's explicit experimental opt-in. */
    fun qualification(experimental: Boolean = false): MulticamQualification = when {
        !known -> MulticamQualification.Unknown
        appears && (preview || experimental) -> MulticamQualification.Qualified
        else -> MulticamQualification.Refused(MulticamQualificationRefusal.UNSUPPORTED_CONFIGURATION)
    }

    internal companion object {
        fun decode(json: JSONObject?): MulticamSupportInfo = MulticamSupportInfo(
            appears = json?.optBoolean("appears") ?: false,
            preview = json?.optBoolean("preview") ?: false,
            missingRoleQueryE0 = json?.optBoolean("missingRoleQueryE0") ?: false,
            known = json?.let {
                it.opt("appears") is Boolean && it.opt("preview") is Boolean && it.opt("missingRoleQueryE0") is Boolean
            } == true,
        )
    }
}

private val supportCache = HashMap<String, MulticamSupportInfo>()

fun FoundCamera.multicamSupport(): MulticamSupportInfo {
    val key = "${modelId ?: -1}|$name|${model.name}"
    synchronized(supportCache) { supportCache[key]?.let { return it } }
    val request = JSONObject().put("name", model.name.ifEmpty { name })
    modelId?.let { request.put("modelId", it) }
    val raw = if (DjiNative.isAvailable) DjiNative.multicamDecision("support", request.toString()) else null
    val json = raw?.let { runCatching { JSONObject(it) }.getOrNull() }
    val info = MulticamSupportInfo.decode(json)
    // A missing native library is not a cached refusal; retry when the integration is available.
    if (info.known) synchronized(supportCache) { supportCache[key] = info }
    return info
}

val FoundCamera.appearsInMultiview: Boolean get() = multicamSupport().appears

val FoundCamera.hasMultiviewPreview: Boolean get() = multicamSupport().preview
