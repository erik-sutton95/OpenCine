package com.opencapture.opencine.vocabulary

import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue

// The ladder popup as values (Swift twin: OpenCineCameraVocabulary/CaptureLadderSheet.swift): a camera
// integration builds it from what the body advertises, and the shared LadderSheet
// (camera-controls) draws it inside the common drawer.

/**
 * A tab whose drum is a typed common setting: the values the camera offers on this tab, in the
 * common vocabulary, so the drum shows the session's field limited to them.
 */
data class CaptureLadderSetting(val key: SettingKey, val offered: List<SettingValue>)

/** One write the sheet asks the host to make: the host's own key and a camera label. */
data class LadderWrite<K>(val key: K, val value: String)

/**
 * A button beside the drum's selected value (Kelvin -10/+10, a codec's two bit depths).
 * [value] null disables the button. [lands] true means the written value becomes the drum's value.
 */
data class LadderStep(
    val label: String,
    val value: String?,
    val description: String,
    val selected: Boolean = false,
    val lands: Boolean = false,
)

/**
 * One tab: a typed common setting (drawn by MonitorCaptureDrum when the session offers the
 * field) or a label ladder (the shared horizontal drum).
 */
data class LadderTab<K>(
    val label: String,
    val key: K,
    val ladder: CaptureLadder,
    val detail: String? = null,
    val activate: LadderWrite<K>? = null,
    val applyOnActivate: Boolean = true,
    val disabled: Boolean = false,
    val setting: CaptureLadderSetting? = null,
    val tint: CaptureTint? = null,
    val values: ((landed: String) -> List<String>)? = null,
    val steps: ((selected: String) -> Pair<LadderStep, LadderStep>?)? = null,
    /** Spoken on the drum when it carries steps: what the buttons beside the value do. */
    val stepsHint: String? = null,
)

data class LadderSheetPresentation<K>(
    val title: String,
    val subtitle: String,
    val tabs: List<LadderTab<K>>,
    val initialTab: Int = 0,
    val lock: CaptureLock? = null,
    val lockBanner: String? = null,
)
