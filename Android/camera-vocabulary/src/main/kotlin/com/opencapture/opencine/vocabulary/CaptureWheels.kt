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
        val codes = profile.colorModes ?: CameraModel.colorModesFor(name, family)
        return codes.map { it to CameraCommands.colorLabel(it, family, profile) }
    }

    fun colorWheel(
        family: String,
        available: List<Int> = emptyList(),
        name: String = "",
        profile: CameraLabelProfile = CameraLabelProfile.standard,
    ): List<Pair<Int, String>> {
        val order = colorWheelOrder(name, family, profile)
        if (available.isEmpty()) return order
        val have = available.toSet()
        val ranked = order.filter { it.first in have }
        return ranked.ifEmpty { order }
    }
}
