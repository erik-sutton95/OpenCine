package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.insta360.shell.CameraControls
import com.opencapture.opencine.insta360.shell.CameraGimbalAngle
import com.opencapture.opencine.motion.GimbalWaypoint
import com.opencapture.opencine.motion.MotionCapabilities
import com.opencapture.opencine.motion.MotionService
import com.opencapture.opencine.motion.MotionProgramTiming
import com.opencapture.opencine.motion.MotionTarget
import kotlin.math.abs
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The Luna gimbal (cmd 226) over the backend's [CameraControls] (Swift `LunaMotionService`): the
 * held stick as a MOVE stream, release, recenter, flip, SET_ANGLE and GET_ANGLE, with the shared
 * [MotionService] over them. The shared MotionProgramSession runs programmed targets; aim and
 * levelling use [hasReached]. A bound service captures a LunaCameraSession/epoch for a take,
 * rather than asking a reusable backend for whichever camera is current. The stick stream runs in [scope].
 */
class LunaMotionService private constructor(
    private val commands: Commands,
    private val scope: CoroutineScope,
    private val now: () -> MonotonicInstant = MonotonicInstant::now,
) : MotionService {
    constructor(controls: () -> CameraControls?, scope: CoroutineScope,
        now: () -> MonotonicInstant = MonotonicInstant::now) : this(BackendCommands(controls), scope, now)
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
                commands.stick(p, t)
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
    suspend fun release(): Boolean = commands.stick(0.0, 0.0)

    override suspend fun recenter(): Boolean = commands.recenter()

    suspend fun flip(): Boolean = commands.flip()

    /** SET_ANGLE at [pose] (handle frame): yaw back to +-180, pitch kept inside the declared reach. The camera re-targets on every SET. */
    suspend fun aim(pose: GimbalWaypoint): Boolean {
        val pitch = pose.pitchDeg.coerceIn(capabilities.bounds.tilt)
        return commands.setAngle(pitch, Math.IEEEremainder(pose.yawDeg, 360.0))
    }

    /** GET_ANGLE; also updates [poses]. */
    suspend fun readAngle(): CameraGimbalAngle? {
        val angle = commands.angle() ?: return null
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
        return commands.available
    }

    /** Luna plans each SET_ANGLE as its own move, so only `duration == null` is accepted. */
    override suspend fun move(target: MotionTarget, duration: Duration?): Boolean =
        duration == null && aim(target.pose)

    override suspend fun stop(): Boolean {
        endHold()
        return release()
    }

    companion object {
        /** Existing approach countdown and SET_ANGLE cadence, supplied to the shared owner. */
        val PROGRAM_TIMING = MotionProgramTiming(3.seconds, 33.milliseconds)

        /** Nil while unowned/not ready. Reentry into the same session retires this epoch-bound service. */
        fun boundTo(session: LunaCameraSession, scope: CoroutineScope,
            now: () -> MonotonicInstant = MonotonicInstant::now): LunaMotionService? {
            val snapshot = session.snapshots.value
            if (snapshot.connection != ConnectionState.Ready || snapshot.authority != ControlAuthority.Owner) return null
            return LunaMotionService(SessionCommands(session, snapshot.epoch), scope, now)
        }
        /** A held stick repeats MOVE at this period. */
        const val STICK_INTERVAL_MS = 50L

        /** GET_ANGLE within the arrival tolerance of [target] on each axis, yaw across +-180. */
        fun hasReached(angle: CameraGimbalAngle, target: GimbalWaypoint): Boolean {
            val tolerance = LunaCameraSession.MOTION.arrivalToleranceDeg
            return abs(Math.IEEEremainder(angle.yaw - target.yawDeg, 360.0)) <= tolerance &&
                abs(angle.pitch - target.pitchDeg) <= tolerance
        }
    }

    /** Coherent wire-domain boundary; both live manual controls and captured takes implement every operation. */
    private interface Commands {
        val available: Boolean
        suspend fun stick(pan: Double, tilt: Double): Boolean
        suspend fun recenter(): Boolean
        suspend fun flip(): Boolean
        suspend fun setAngle(pitch: Double, yaw: Double): Boolean
        suspend fun angle(): CameraGimbalAngle?
    }

    private class BackendCommands(private val controls: () -> CameraControls?) : Commands {
        override val available: Boolean get() = controls() != null
        override suspend fun stick(pan: Double, tilt: Double): Boolean = controls()?.gimbalStick(pan, tilt) == true
        override suspend fun recenter(): Boolean = controls()?.gimbalRecenter() == true
        override suspend fun flip(): Boolean = controls()?.gimbalFlip() == true
        override suspend fun setAngle(pitch: Double, yaw: Double): Boolean = controls()?.gimbalSetAngle(pitch, yaw) == true
        override suspend fun angle(): CameraGimbalAngle? = controls()?.gimbalAngle()
    }

    private class SessionCommands(private val session: LunaCameraSession, private val epoch: ControlEpoch) : Commands {
        override val available: Boolean get() = session.snapshots.value.let {
            it.connection == ConnectionState.Ready && it.authority == ControlAuthority.Owner && it.epoch == epoch
        }
        private suspend fun request(request: LunaControl.Request, timeoutMs: Long? = null,
            commanding: Boolean = false): ByteArray? = runCatching {
            if (timeoutMs == null) session.motionRequest(request, epoch, commanding)
            else withTimeoutOrNull(timeoutMs) { session.motionRequest(request, epoch, commanding) }
        }.getOrNull()

        override suspend fun stick(pan: Double, tilt: Double): Boolean =
            request(LunaControl.gimbalStick(pan, tilt), commanding = pan != 0.0 || tilt != 0.0) != null
        override suspend fun recenter(): Boolean = request(LunaControl.gimbal(2)) != null
        override suspend fun flip(): Boolean = request(LunaControl.gimbal(3)) != null
        override suspend fun setAngle(pitch: Double, yaw: Double): Boolean =
            request(LunaControl.gimbalSetAngle(pitch.toFloat(), yaw.toFloat()), 2_000, commanding = true) != null
        override suspend fun angle(): CameraGimbalAngle? {
            val reply = request(LunaControl.gimbalGetAngle, 1_000) ?: return null
            return runCatching { LunaControl.gimbalAngle(reply) }.getOrNull()?.let {
                CameraGimbalAngle(it.pitch.toDouble(), it.yaw.toDouble())
            }
        }
    }
}
