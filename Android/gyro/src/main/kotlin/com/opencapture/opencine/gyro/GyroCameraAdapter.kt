package com.opencapture.opencine.gyro

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

/** One gravity vector in fixed device axes. */
data class GyroVector3(val x: Double, val y: Double, val z: Double)

/** The active camera body; the id is stable across reconnects. */
data class GyroCameraIdentity(
    val id: String,
    val name: String,
    /** False when a model-only fallback must not match another body's pending restore. */
    val automaticRestoreEligible: Boolean = true,
)

/** One stabilization setting the camera exposes as an on/off choice. */
data class GyroStabilizationSetting(val key: String, val title: String, val offValue: String)

/** Current stabilization values, with whether the lens offers a switch when the camera knows. */
data class GyroStabilizationState(val values: Map<String, String>, val lensHasVRSwitch: Boolean?)

/** One camera level observation; [down] is null when the camera has no level reading. */
data class GyroCameraLevel(val down: GyroVector3?, val timestampSeconds: Double)

/**
 * The app's camera-side port of the gyro engine: identity, movie mode, recording, stabilization
 * values and the level stream, all as values. Writes stay on the adapter so the module commands
 * no camera and names no manufacturer (Swift twin: OpenCineGyro's GyroCameraAdapter).
 */
interface GyroCameraAdapter {
    /** The connected camera, or null when none is connected. */
    val identity: StateFlow<GyroCameraIdentity?>

    /** Camera recording state, or null when the camera does not report it. */
    val recording: StateFlow<Boolean?>

    /** Whether the camera is in movie mode, or null when unknown. */
    val videoMode: StateFlow<Boolean?>

    /** Current stabilization values, or null when the camera does not report them. */
    val stabilization: StateFlow<GyroStabilizationState?>

    /** Camera level readings; empty when the camera has no level sensor. */
    val level: Flow<GyroCameraLevel>

    /** False when the camera has no level sensor. */
    val providesLevel: Boolean

    /** Stabilization controls the adapter exposes to the arming setup sheet. */
    val stabilizationSettings: List<GyroStabilizationSetting>

    /**
     * Writes these stabilization values; false when the camera refused the write. It must return
     * (false) when the connection ends; the coordinator also gives up after
     * [GYRO_WRITE_TIMEOUT_MILLIS] and treats the write as refused.
     */
    suspend fun writeStabilization(values: Map<String, String>): Boolean
}

/** Current host and camera observations the arming machine evaluates. */
data class GyroArmingInputs(
    /** The saved gyro toggle: arm whenever possible. */
    val toggleOn: Boolean,
    /** Active camera body, or null when not connected. */
    val camera: GyroCameraIdentity?,
    /** Monitor showing, app in front, and no multicam or relay. */
    val hostEligible: Boolean,
    /** Camera in movie mode; null when unknown. */
    val videoMode: Boolean?,
    /** Camera recording; null when unknown. */
    val recording: Boolean?,
    /** Current stabilization values; null when the camera reports them unavailable. */
    val stabilization: GyroStabilizationState?,
    /** Stabilization controls the camera adapter exposes. */
    val settings: List<GyroStabilizationSetting>,
    /** False when the camera has no level sensor. */
    val providesLevel: Boolean,
    /** Whether a calibration is saved for this camera. */
    val hasSavedCalibration: Boolean,
)
