package com.opencapture.opencine.gyro

/**
 * What the compact gyro pill on the monitor shows. The Swift twin is `GyroPillKind`; both read
 * `Fixtures/gyro-pill-vectors.tsv`.
 */
enum class GyroPillKind {
    /** Gyro is off and nothing failed: no pill. */
    HIDDEN,

    /** Gyro is on but not armed and collecting yet (no camera, not eligible, or starting). */
    OFFLINE,

    /** Armed and collecting motion between takes. */
    ARMED,

    /** A take is open while the camera reports recording. */
    RECORDING,

    /** A take is still open after the camera stopped recording (being finished on disk). */
    SAVING,

    /** A take is open and the sensor has gaps. */
    GAPS,

    /** The mount moved during the open take. */
    MOUNT_MOVED,

    /** Logging failed; the pill opens the logs. */
    ERROR,
}

/**
 * The pill's resolved state: its [kind] plus the "IBIS is still on" warning mark. A hidden pill
 * never carries the warning, whatever is passed.
 */
class GyroPillState(val kind: GyroPillKind, stabilizationWarning: Boolean) {
    /** True when the camera's stabilization is still on while gyro is armed. */
    val stabilizationWarning: Boolean = kind != GyroPillKind.HIDDEN && stabilizationWarning

    /** Value equality on [kind] and [stabilizationWarning]. */
    override fun equals(other: Any?): Boolean =
        other is GyroPillState && other.kind == kind &&
            other.stabilizationWarning == stabilizationWarning

    /** Hash consistent with [equals]. */
    override fun hashCode(): Int = kind.hashCode() * 31 + stabilizationWarning.hashCode()

    /** Debug text. */
    override fun toString(): String =
        "GyroPillState(kind=$kind, stabilizationWarning=$stabilizationWarning)"

    /** Shared instances. */
    companion object {
        /** No pill. */
        val HIDDEN_STATE: GyroPillState = GyroPillState(GyroPillKind.HIDDEN, false)
    }
}

/**
 * Resolves the pill from the capture facts. Precedence, first match wins: hidden (off and not
 * failed), error, mount moved (in a take), gaps (in a take), recording (in a take while the
 * camera reports REC), saving (any other open take), armed (armed, motion running and a first
 * sample seen), otherwise offline. The warning passes through except when hidden.
 */
fun resolveGyroPill(
    enabled: Boolean,
    failed: Boolean,
    armed: Boolean,
    motionRunning: Boolean,
    hasFirstSample: Boolean,
    activeTake: Boolean,
    cameraRecording: Boolean?,
    gapWarning: Boolean,
    mountMoved: Boolean,
    stabilizationWarning: Boolean,
): GyroPillState {
    val kind = when {
        !enabled && !failed -> GyroPillKind.HIDDEN
        failed -> GyroPillKind.ERROR
        activeTake && mountMoved -> GyroPillKind.MOUNT_MOVED
        activeTake && gapWarning -> GyroPillKind.GAPS
        activeTake && cameraRecording == true -> GyroPillKind.RECORDING
        activeTake -> GyroPillKind.SAVING
        armed && motionRunning && hasFirstSample -> GyroPillKind.ARMED
        else -> GyroPillKind.OFFLINE
    }
    return GyroPillState(kind, stabilizationWarning)
}
