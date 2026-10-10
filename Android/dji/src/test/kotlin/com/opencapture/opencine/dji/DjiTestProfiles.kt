package com.opencapture.opencine.dji

import com.opencapture.opencine.vocabulary.CameraModel
import org.json.JSONObject

/** Original donor fixtures now declare the same known facade facts through the integration. */
internal fun djiBodyProfile(name: String, family: String = "pocket"): CameraModel =
    CameraModel.fromJson(JSONObject().put("name", name).put("family", family)
        .put("hasGimbal", family == "pocket").put("supportsZoom", family == "pocket")
        .put("supportsFocusMode", true).put("supportsTapFocus", true).toString())
