package com.opencapture.monitorui

/**
 * [persisted] is the saved key. [STOPS] is the scale now labeled Video; its key stays
 * "CineStop" so saved settings keep the scale they chose. CineStop is [SCENE_STOPS].
 */
enum class MonitorFalseColorSelection(val persisted: String, val menuLabel: String) {
    SCENE_STOPS("SceneStops", "CineStop"),
    STOPS("CineStop", "Video"),
    IRE("IRE", "IRE"),
    LIMITS("Limits", "Limits"),
    ;

    val usesSceneStops: Boolean get() = this == SCENE_STOPS

    companion object {
        fun fromPersisted(raw: String): MonitorFalseColorSelection =
            entries.firstOrNull { it.persisted == raw || it.name == raw }
                ?: when (raw) {
                    "Stops", "ZC Stops", "PStops" -> STOPS
                    else -> SCENE_STOPS
                }

        fun fromMenuLabel(label: String): MonitorFalseColorSelection =
            when (label) {
                "Video" -> STOPS
                "IRE" -> IRE
                "Limits" -> LIMITS
                else -> SCENE_STOPS
            }
    }
}

enum class MonitorZebraUnit(val persisted: String, val editorLabel: String) {
    NATIVE("Native", "0-255"),
    IRE("IRE", "IRE"),
    ;

    companion object {
        fun fromPersisted(raw: String): MonitorZebraUnit =
            entries.firstOrNull { it.persisted == raw || it.editorLabel == raw || it.name == raw }
                ?: IRE

        fun fromEditorLabel(label: String): MonitorZebraUnit = if (label == "0-255") NATIVE else IRE
    }
}
