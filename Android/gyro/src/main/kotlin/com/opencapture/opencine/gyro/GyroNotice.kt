package com.opencapture.opencine.gyro

/**
 * A capture problem the host shows to the operator. The shared UI resolves the wording; the
 * Swift twin is `GyroNotice` in OpenCineGyro with the same cases in the same order.
 */
enum class GyroNotice {
    /** The camera refused the stabilization turn-off write; IBIS is still on. */
    TURN_OFF_FAILED,

    /** The saved stabilization could not be restored. */
    RESTORE_FAILED,

    /** The phone's gyroscope is unavailable. */
    SENSOR_UNAVAILABLE,

    /** The sensor stopped reporting during capture. */
    SENSOR_STALLED,

    /** Samples were lost faster than they could be written. */
    SAMPLES_LOST,

    /** Recording events could not be saved in time. */
    RECORDING_EVENTS_LOST,

    /** A log could not be written. */
    SAVE_FAILED,

    /** The saved logs could not be opened. */
    OPEN_FAILED,

    /** A log cannot be shared (still recording or missing). */
    SHARE_FAILED,

    /** A log could not be deleted. */
    DELETE_FAILED,

    /** Some interrupted logs could not be recovered on launch. */
    RECOVERY_INCOMPLETE,
}
