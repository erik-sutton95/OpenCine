package com.opencapture.monitorui

/** Current monitor-assist identities. Sources provide availability and choose their tool ordering. */
enum class MonitorAssistTool {
    LUT,
    PEAK,
    FALSE,
    ZEBRA,
    WAVE,
    PARADE,
    HISTO,
    VECTOR,
    LIGHTS,
    ND,
    EV,
    AUDIO,
    GUIDES,
    GRID,
    CROSS,
    LEVEL,
    DESQ,
    MIRROR,
    ;

    val chipLabel: String
        get() = if (this == DESQ) "DE-SQ" else name

    val label: String
        get() = name

    /** Settings names, matching the shared Swift catalog. */
    val displaySettingsTitle: String
        get() = when (this) {
            PARADE -> "Parade"
            ND -> "ND"
            else -> title
        }

    val title: String
        get() =
            when (this) {
                LUT -> "LUT"
                PEAK -> "Peaking"
                FALSE -> "False Color"
                ZEBRA -> "Zebra"
                WAVE -> "Waveform"
                PARADE -> "RGB Parade"
                HISTO -> "Histogram"
                VECTOR -> "Vectorscope"
                LIGHTS -> "Traffic Lights"
                ND -> "ND Suggestion"
                EV -> "EV Meter"
                AUDIO -> "Audio Levels"
                GUIDES -> "Guides"
                GRID -> "Grid"
                CROSS -> "Crosshair"
                LEVEL -> "Level"
                DESQ -> "Anamorphic Desqueeze"
                MIRROR -> "Mirror"
            }

    /** The fixed camera EV meter and LEVEL are tap-only toggles. */
    val hasConfiguration: Boolean
        get() =
            when (this) {
                EV, LEVEL -> false
                else -> true
            }

    companion object {
        val toolbarGroups: List<List<MonitorAssistTool>> get() =
            listOf(
                listOf(LUT, PEAK, FALSE),
                listOf(ZEBRA, WAVE, PARADE),
                listOf(HISTO, VECTOR, LIGHTS, ND, EV),
                listOf(GUIDES, GRID, CROSS, LEVEL, DESQ),
                listOf(MIRROR),
            )

        /** AUDIO is appended as its own trailing section. */
        val toolbarCases: List<MonitorAssistTool> get() = toolbarGroups.flatten()

        /** Camera EV and LEVEL have no clip telemetry; AUDIO rides last like live. */
        val playbackToolbarCases: List<MonitorAssistTool> get() = toolbarCases.filter { it != EV && it != LEVEL } + AUDIO

        /**
         * What a still photo offers, in playback order (Swift `MonitorAssistSelection.photoToolbarCases`).
         * No LUT: the assist cubes convert the camera's log curve and a still is display-referred
         * Rec.709. No ND, AUDIO, LEVEL or EV: a still has no exposure to change, no sound and no attitude.
         */
        val photoToolbarCases: List<MonitorAssistTool> get() = playbackToolbarCases.filter {
            it in setOf(PEAK, FALSE, ZEBRA, WAVE, PARADE, HISTO, VECTOR, LIGHTS, GUIDES, GRID, CROSS, DESQ, MIRROR)
        }

        /** Photo tools that remake the still's pixels; a page offers them only with a still look renderer. */
        val photoPictureTools: Set<MonitorAssistTool> get() = setOf(PEAK, FALSE, ZEBRA)

        val settingsCases: List<MonitorAssistTool> get() = toolbarCases + AUDIO

        val cleanPinCases: List<MonitorAssistTool> get() = settingsCases.filter { it != EV }

        fun fromPersisted(raw: String): MonitorAssistTool? =
            entries.firstOrNull { it.name == raw || it.chipLabel == raw }
    }
}
