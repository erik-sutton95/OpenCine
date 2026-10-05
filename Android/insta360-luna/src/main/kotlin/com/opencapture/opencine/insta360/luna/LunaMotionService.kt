package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.insta360.shell.CameraControls
import com.opencapture.opencine.insta360.shell.CameraGimbalAngle
import com.opencapture.opencine.motion.GimbalWaypoint
import com.opencapture.opencine.motion.MotionCapabilities
import com.opencapture.opencine.motion.MotionService
import com.opencapture.opencine.motion.MotionTarget
import kotlin.math.abs
import kotlin.time.Duration
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * The Luna gimbal (cmd 226) over the backend's [CameraControls] (Swift `LunaMotionService`): the
 * held stick as a MOVE stream, release, recenter, flip, SET_ANGLE and GET_ANGLE, with the shared
 * [MotionService] over them. The app runs aim until arrival, levelling and programmed moves
 * against its live state, on [hasReached] and the shared `GimbalProgram.pose`. The stick stream
 * runs in [scope].
 */
class LunaMotionService(
    private val controls: () -> CameraControls?,
    private val scope: CoroutineScope,
    private val now: () -> MonotonicInstant = MonotonicInstant::now,
) : MotionService {
    override val capabilities: MotionCapabilities get() = LunaCameraSession.MOTION

    private val _poses = MutableStateFlow<ObservedValue<GimbalWaypoint>>(ObservedValue.unknown)
    /** The newest GET_ANGLE as a pose, unknown until the camera answers one. */
    override val poses: StateFlow<ObservedValue<GimbalWaypoint>> = _poses.asStateFlow()

    @Volatile private var stick = 0.0 to 0.0
    private var stream: Job? = null
    val isHeld: Boolean get() = stream?.isActive == true

    /**
     * Holds the stick at each axis -1..1 of full speed and repeats MOVE every [STICK_INTERVAL_MS]
     * until [endHold]. A held stick at 0, 0 keeps repeating: on Luna that is the release itself.
     */
    fun hold(pan: Double, tilt: Double) {
        stick = pan to tilt
        if (isHeld) return
        stream = scope.launch {
            while (isActive) {
                val (p, t) = stick
                controls()?.gimbalStick(p, t)
                delay(STICK_INTERVAL_MS)
            }
        }
    }

    /** Stops repeating MOVE; the caller sends [release] when it wants the head at rest. */
    fun endHold() {
        stream?.cancel()
        stream = null
        stick = 0.0 to 0.0
    }

    /** VirtualRC rest. */
    suspend fun release(): Boolean = controls()?.gimbalStick(0.0, 0.0) == true

    override suspend fun recenter(): Boolean = controls()?.gimbalRecenter() == true

    suspend fun flip(): Boolean = controls()?.gimbalFlip() == true

    /** SET_ANGLE at [pose] (handle frame): yaw back to +-180, pitch kept inside the declared reach. The camera re-targets on every SET. */
    suspend fun aim(pose: GimbalWaypoint): Boolean {
        val pitch = pose.pitchDeg.coerceIn(capabilities.bounds.tilt)
        return controls()?.gimbalSetAngle(pitch, Math.IEEEremainder(pose.yawDeg, 360.0)) == true
    }

    /** GET_ANGLE; also updates [poses]. */
    suspend fun readAngle(): CameraGimbalAngle? {
        val angle = controls()?.gimbalAngle() ?: return null
        // Unwrapped across the unreachable gap; Luna moves carry no zoom, so a pose keeps the neutral 1.
        val yaw = GimbalWaypoint.unwrapYaw(angle.yaw, capabilities.bounds)
        _poses.value = ObservedValue(
            GimbalWaypoint(yaw, angle.pitch, 1.0, -angle.pitch), ObservationOrigin.CAMERA_REPORTED, now(),
        )
        return angle
    }

    override suspend fun stick(pan: Double, tilt: Double): Boolean {
        if (pan == 0.0 && tilt == 0.0) return stop()
        hold(pan, tilt)
        return controls() != null
    }

    /** Luna plans each SET_ANGLE as its own move, so only `duration == null` is accepted. */
    override suspend fun move(target: MotionTarget, duration: Duration?): Boolean =
        duration == null && aim(target.pose)

    override suspend fun stop(): Boolean {
        endHold()
        return release()
    }

    companion object {
        /** A held stick repeats MOVE at this period. */
        const val STICK_INTERVAL_MS = 50L

        /** GET_ANGLE within the arrival tolerance of [target] on each axis, yaw across +-180. */
        fun hasReached(angle: CameraGimbalAngle, target: GimbalWaypoint): Boolean {
            val tolerance = LunaCameraSession.MOTION.arrivalToleranceDeg
            return abs(Math.IEEEremainder(angle.yaw - target.yawDeg, 360.0)) <= tolerance &&
                abs(angle.pitch - target.pitchDeg) <= tolerance
        }
    }
}
