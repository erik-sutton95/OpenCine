package com.opencapture.opencine.vocabulary

/** Integration-declared camera looks. Identity never participates in shared resolution. */
data class CameraLUTProfile(
    val automatic: Map<Int, LutLookSource> = emptyMap(),
    val selections: Map<String, LutLookSource> = emptyMap(),
    val cameraLooks: List<LutEntry> = emptyList(),
)
