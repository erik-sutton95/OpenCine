package com.opencapture.opencine.gyro

/**
 * The coordinator's mount-drift detector: one drift owner per armed session, created with the
 * session's frozen calibration the first time a calibrated take records, reset at each take
 * start, closed at session end and after a new calibration. Confirmation comes only from the
 * drift wire.
 */
internal class GyroCaptureDrift(private val native: GyroNativeApi) {
    private var owner: String? = null

    /** True once this armed session's operator chose "Not now". */
    var dismissed: Boolean = false

    /** A mount move was confirmed in the current take; the prompt waits for REC to stop. */
    var pendingPrompt: Boolean = false

    /** Whether a detector owner is open. */
    val active: Boolean get() = owner != null

    /** Opens the detector for [calibration] if none is open; false when the wire refuses it. */
    fun ensure(calibration: String, level: GyroCameraLevel?): Boolean {
        if (owner != null) return true
        owner = native.driftCreate(calibration) ?: return false
        level?.let(::observeCamera)
        return true
    }

    /** Clears partial runs and the confirmation for a new take. */
    fun reset() {
        owner?.let(native::driftReset)
        pendingPrompt = false
    }

    /** Forwards the newest camera level. */
    fun observeCamera(level: GyroCameraLevel) {
        val active = owner ?: return
        val down = level.down
        native.driftObserveCamera(
            active, down != null, down?.x ?: 0.0, down?.y ?: 0.0, down?.z ?: 0.0,
            level.timestampSeconds,
        )
    }

    /** Forwards one phone reading; true exactly once, on the confirming reading. */
    fun observePhone(reading: GyroMotionReading): Boolean {
        val active = owner ?: return false
        return native.driftObservePhone(
            active,
            reading.phoneDown.x,
            reading.phoneDown.y,
            reading.phoneDown.z,
            reading.timestamp,
            reading.rotationRate,
            reading.accelerationG,
        )
    }

    /** Closes the owner; [endSession] also forgets this session's dismissal and pending prompt. */
    fun close(endSession: Boolean) {
        owner?.let(native::driftClose)
        owner = null
        if (endSession) {
            dismissed = false
            pendingPrompt = false
        }
    }
}
