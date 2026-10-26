package com.opencapture.opencine.gyro

/** The ring screen's first state, before "Get started" creates a ring owner. */
internal val GYRO_RING_INTRO =
    GyroRingState(
        phase = GyroRingPhase.INTRO,
        step = null,
        inZone = null,
        hold = null,
        block = null,
        invalidation = null,
        completedSteps = 0,
        event = null,
        calibrationJSON = null,
    )

/**
 * The coordinator's ring calibration: one ring owner at a time, retired exactly once (the retire-once
 * rule of the calibration session this replaces), and a completed calibration published only after
 * `calibrationValidate`. Every phase decision comes from the ring wire.
 */
internal class GyroCaptureCalibration(private val native: GyroNativeApi) {
    private var owner: String? = null

    /** What the ring screen shows; null when calibration is not presented. */
    var state: GyroRingState? = null
        private set

    /** True when the ring was opened from the arming setup sheet. */
    var fromSetup: Boolean = false
        private set

    /** Ring events seen so far (any non-null reply event); only ever increases. */
    var eventCount: Int = 0
        private set

    /** True while a ring owner exists and needs motion readings. */
    val needsMotion: Boolean get() = owner != null

    /** Shows the intro without creating an owner or starting sensors. */
    fun begin(fromSetup: Boolean) {
        retire()
        this.fromSetup = fromSetup
        state = GYRO_RING_INTRO
    }

    /** "Get started": replaces any owner with a fresh started ring. */
    fun start(connected: Boolean, recording: Boolean?) {
        if (state == null) return
        retire()
        val created = native.ringCreate()
        owner = created
        accept(native.ringStart(created, connected, recording.wire()))
    }

    /** Feeds one phone reading with the newest camera level; returns a verified calibration once. */
    fun observe(reading: GyroMotionReading, level: GyroCameraLevel?): String? {
        val active = owner ?: return null
        val down = level?.down
        val reply =
            native.ringObserve(
                active,
                reading.phoneDown.x,
                reading.phoneDown.y,
                reading.phoneDown.z,
                reading.timestamp,
                down != null,
                down?.x ?: 0.0,
                down?.y ?: 0.0,
                down?.z ?: 0.0,
                level?.timestampSeconds ?: 0.0,
            )
        val next = accept(reply) ?: return null
        if (next.event != GyroRingEvent.COMPLETED) return null
        val calibration = next.calibrationJSON
        retire()
        if (calibration == null || !native.calibrationValidate(calibration)) {
            state = GYRO_RING_INTRO
            throw IllegalStateException("The ring calibration did not verify.")
        }
        return calibration
    }

    /** Forwards a camera state change; the wire invalidates or blocks. */
    fun updateCamera(connected: Boolean, recording: Boolean?) {
        val active = owner ?: return
        accept(native.ringUpdateCamera(active, connected, recording.wire()))
    }

    /** Discards an in-progress ring for [reason]. */
    fun invalidate(reason: GyroCalibrationInvalidation) {
        val active = owner ?: return
        accept(native.ringInvalidate(active, reason.wire))
    }

    /**
     * Closes the screen and its owner. [cancel] (the operator backed out) first tells the wire
     * with `ringCancel`, so the ring discards its poses before the owner is retired.
     */
    fun close(cancel: Boolean = false) {
        if (cancel) owner?.let { native.ringCancel(it) }
        retire()
        state = null
        fromSetup = false
    }

    /** Back to the intro after a calibration that could not be saved; the owner is retired. */
    fun returnToIntro() {
        retire()
        state = GYRO_RING_INTRO
    }

    private fun accept(json: String?): GyroRingState? {
        val next = decodeRingReply(json ?: return null)
        state = next
        if (next.event != null) eventCount += 1
        if (next.phase == GyroRingPhase.INVALIDATED) retire()
        return next
    }

    private fun retire() {
        owner?.let(native::ringClose)
        owner = null
    }
}

private fun Boolean?.wire(): Int =
    when (this) {
        null -> -1
        false -> 0
        true -> 1
    }
