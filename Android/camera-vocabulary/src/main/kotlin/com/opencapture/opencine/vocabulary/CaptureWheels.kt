package com.opencapture.opencine.vocabulary

import kotlin.math.abs

/**
 * The capture value lists the session itself needs (ISO wheel, color wheel, nearest shutter).
 * The sheet lists (`CaptureLists` in camera-controls) delegate here, so both read one table.
 * [CameraLabelProfile] carries a session's own labels and color wheel (default: the body's list).
 */
object CaptureWheels {
    fun isoFallback(colorMode: Int): List<Int> = CameraCommands.isoChoices(colorMode).map { it.first }

    /** Photo must not reuse leftover Video color for Auto ISO / fallback wheels. */
    fun isoPresentationColor(status: CameraStatus): Int = status.monitorColorMode

    fun isoIndices(status: CameraStatus): List<Int> =
        CameraCommands.isoWheelIndices(
            status.availableIsoIndices,
            isoFallback(isoPresentationColor(status)),
        )

    fun offersIsoAuto(status: CameraStatus): Boolean =
        CameraCommands.offersIsoAuto(isoPresentationColor(status))

    fun nearestDenom(current: Int, denoms: List<Int>): Int? =
        denoms.minByOrNull { abs(it - current) }

    fun colorWheelOrder(name: String, family: String, profile: CameraLabelProfile = CameraLabelProfile.standard): List<Pair<Int, String>> {
        val codes = profile.colorModes.orEmpty()
        return codes.map { it to CameraCommands.colorLabel(it, family, profile) }
    }

    fun colorWheel(
        family: String,
        available: List<Int> = emptyList(),
        name: String = "",
        profile: CameraLabelProfile = CameraLabelProfile.standard,
    ): List<Pair<Int, String>> {
        val order = colorWheelOrder(name, family, profile)
        if (order.isEmpty()) return available.map { it to CameraCommands.colorLabel(it, family, profile) }
        if (available.isEmpty()) return order
        val have = available.toSet()
        val ranked = order.filter { it.first in have }
        return ranked.ifEmpty { order }
    }

    /**
     * The colour drum: the [offered] modes plus the camera's reported [current] mode when the
     * offered list lacks it, so the popup opens centred on the value the header shows. That extra
     * entry is shown, never sent: a SET goes only to an offered mode. Unknown (-1) adds nothing.
     * Swift twin: `CamCapColorMode.drum`.
     */
    fun colorDrum(
        offered: List<Pair<Int, String>>,
        current: Int,
        family: String,
        profile: CameraLabelProfile = CameraLabelProfile.standard,
    ): List<Pair<Int, String>> {
        if (current < 0 || offered.any { it.first == current }) return offered
        val label = CameraCommands.colorLabel(current, family, profile)
        return if (label == CameraCommands.colorLabel(-1, family)) offered else offered + (current to label)
    }
}
