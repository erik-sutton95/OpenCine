package com.opencapture.opencine.gyro

import kotlin.math.roundToLong
import org.json.JSONObject

/**
 * Why a saved or recording gyro take needs operator attention, from the take's own facts.
 * The declaration order is the precedence [resolveGyroTakeStatus] applies.
 */
sealed interface GyroTakeStatus {
    /** Motion is being collected for a take that is still recording. */
    data object Recording : GyroTakeStatus

    /** The mount moved after REC start; the offset is measured from the observed REC start. */
    data class MountMoved(val offsetSeconds: Double) : GyroTakeStatus

    /** The take ended early, has no summary yet, or was already incomplete when it began. */
    data object CutShort : GyroTakeStatus

    /** The take completed but lost samples or has a sensor gap. */
    data object SmallGaps : GyroTakeStatus

    /** No verified mount calibration is stored, including logs that carry a manual preset. */
    data object NotCalibrated : GyroTakeStatus

    /** The take is complete, healthy and calibrated. */
    data object Ready : GyroTakeStatus
}

/**
 * Resolves one take's status from its descriptor, optional summary and live recording state.
 * Precedence: recording, then a mount move, then a short or missing take, then sample health,
 * then calibration. A fact that is absent never becomes a healthy status by itself.
 * Swift twin: `GyroTakeStatus.resolve`.
 */
fun resolveGyroTakeStatus(
    descriptor: JSONObject,
    summary: JSONObject?,
    active: Boolean,
): GyroTakeStatus {
    if (active) return GyroTakeStatus.Recording
    if (summary == null) return GyroTakeStatus.CutShort
    val mountMovedOffset = summary.nullableDouble("mountMovedOffset")
    if (mountMovedOffset != null) return GyroTakeStatus.MountMoved(mountMovedOffset)
    val termination = summary.nullableString("termination")
    if (termination != "normal" || descriptor.optBoolean("isPartial")) {
        return GyroTakeStatus.CutShort
    }
    val largestGap = summary.getDouble("largestGap")
    val hasGapWarning = (largestGap * 1_000_000).roundToLong() > 50_000
    if (summary.optBoolean("isPartial") || hasGapWarning ||
        summary.optInt("rejectedSampleCount") > 0
    ) {
        return GyroTakeStatus.SmallGaps
    }
    if (descriptor.isNull("mountCalibration")) return GyroTakeStatus.NotCalibrated
    return GyroTakeStatus.Ready
}

private fun JSONObject.nullableString(name: String): String? =
    if (isNull(name)) null else getString(name)

private fun JSONObject.nullableDouble(name: String): Double? =
    if (isNull(name)) null else getDouble(name)
