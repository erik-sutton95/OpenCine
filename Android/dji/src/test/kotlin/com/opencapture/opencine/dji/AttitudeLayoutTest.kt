package com.opencapture.opencine.dji

import com.opencapture.opencine.motion.GimbalProgram
import com.opencapture.opencine.motion.GimbalWaypoint
import com.opencapture.opencine.motion.WorldLevelSnap
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.GimbalStickMapping
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * OpenPocketCine#621: Pocket 3 on current firmware pushes 49-byte `0x04/0x05` attitude
 * (Swift `GimbalAttitudeLayoutTests`). SYNTHETIC frames: no real 49-byte payload is on file
 * yet, so each frame is built from the documented offsets (native `@0`, yaw `@4`, display
 * pitch `-@20`). Replace with captured frames once the reporter attaches them.
 */
class AttitudeLayoutTest {
    private fun attitude(native: Int, yaw: Int, pitch: Int, count: Int): ByteArray {
        val bytes = ByteArray(maxOf(count, 22))
        fun i16(at: Int, value: Int) {
            bytes[at] = value.toByte()
            bytes[at + 1] = (value shr 8).toByte()
        }
        i16(0, native)
        i16(4, yaw)
        i16(20, -pitch)
        return bytes.copyOf(count)
    }

    private fun nativeTenths(payload: ByteArray?): Int? = payload?.let {
        ((it[4].toInt() and 0xFF) or ((it[5].toInt() and 0xFF) shl 8)).toShort().toInt()
    }

    private fun frame(payload: ByteArray) = DumlFrame(0, 0, 1, 0, 4, 5, payload)

    @Test
    fun compactFramesParseYawAndPitchLikeTheFullLayout() {
        val compact = attitude(1744, -123, 56, 49)
        val full = attitude(1744, -123, 56, 50)
        assertEquals(AttitudeLayout.POCKET3_COMPACT, AttitudeLayout.of(compact))
        assertEquals(AttitudeLayout.FULL, AttitudeLayout.of(full))
        for (payload in listOf(compact, full)) {
            assertTrue(CameraCommands.isAttitude(payload))
            assertEquals(-123, CameraCommands.yawTenthDeg(payload))
            assertEquals(56, CameraCommands.pitchTenthDeg(payload))
            assertEquals(1744, CameraCommands.nativePitchTenthDeg(payload))
            assertEquals(GimbalWaypoint(-12.3, 5.6, 1.0, 174.4), NativeGimbalFeedback.from(frame(payload), 1.0)?.pose)
        }
        assertEquals(NativePitchWire.CONTINUOUS, NativeGimbalFeedback.from(frame(compact), 1.0)?.nativePitch)
        assertEquals(NativePitchWire.WRAPPED, NativeGimbalFeedback.from(frame(full), 1.0)?.nativePitch)
        val mapping = GimbalStickMapping().applyAttitude(compact)
        assertEquals(-123, mapping.yawTenthDeg)
        assertEquals(56, mapping.pitchTenthDeg)
    }

    @Test
    fun otherLengthsStillFailClosed() {
        for (count in listOf(22, 40, 48, 51, 52, 64)) {
            val payload = attitude(1744, 300, 56, count)
            assertNull(AttitudeLayout.of(payload), "length $count")
            assertNull(CameraCommands.yawTenthDeg(payload))
            assertNull(CameraCommands.pitchTenthDeg(payload))
            assertNull(CameraCommands.nativePitchTenthDeg(payload))
            assertNull(NativeGimbalFeedback.from(frame(payload), 1.0))
            val held = GimbalStickMapping(yawTenthDeg = 5, pitchTenthDeg = 7).applyAttitude(payload)
            assertEquals(5, held.yawTenthDeg)
            assertEquals(7, held.pitchTenthDeg)
        }
    }

    @Test
    fun continuousTargetsStayBesideTheirReferenceOrStop() {
        val wire = NativePitchWire.CONTINUOUS
        assertEquals(183.4, wire.target(-176.6, 174.4)!!, 1e-9)
        assertEquals(181.7, wire.target(-178.3, 174.4)!!, 1e-9)
        assertNull(wire.target(0.0, 174.4), "174° from the reference is outside the reach")
        assertNull(wire.target(10.0, 190.0), "a reference is a reported ±180° pitch")
        assertEquals(183.4, wire.wireDeg(183.4, -178.3))
        assertNull(wire.wireDeg(183.4, 20.0), "the gimbal is not near the target")
        assertNull(wire.wireDeg(400.0, 179.0))
        assertEquals(-176.6, NativePitchWire.WRAPPED.target(-176.6, 174.4))
        assertNull(CameraCommands.gimbalTimedTarget(0.0, 183.4, 0.1))
        assertNotNull(CameraCommands.gimbalTimedTarget(0.0, 183.4, 0.1, NativePitchWire.CONTINUOUS))
    }

    /** The engine plans wrapped native pitch from the pose at Start (+174.4°, display +5.6°). */
    @Test
    fun programmedTargetsGoOutBesideTheStartReference() {
        val start = GimbalWaypoint(0.0, 5.6, 1.0, 174.4)
        val b = GimbalMoveEngine.planFromLive(
            GimbalProgram(start, GimbalWaypoint(30.0, -10.0, 1.0, 0.0), durationAB = 2.0), start).b!!
        assertEquals(-170.0, b.nativePitchDeg!!, 1e-9)
        val continuous = CameraCommands.gimbalTimedTarget(
            b.copy(nativePitchDeg = NativePitchWire.CONTINUOUS.target(b.nativePitchDeg!!, 174.4)),
            start, NativePitchWire.CONTINUOUS, null, 2.0)
        assertEquals(1900, nativeTenths(continuous))
        val wrapped = CameraCommands.gimbalTimedTarget(b, start, NativePitchWire.WRAPPED, 174.4, 2.0)
        assertEquals(-1700, nativeTenths(wrapped))
        assertContentEquals(CameraCommands.gimbalTimedTarget(b, 2.0), wrapped)
    }

    @Test
    fun runnerSendsContinuousTargetsBesideTheStartPose() {
        var now = 0.0
        val tasks = mutableListOf<Pair<Double, () -> Unit>>()
        val start = GimbalWaypoint(0.0, 5.6, 1.0, 174.4)
        var sample = NativeGimbalFeedback(start, 0.0, nativePitch = NativePitchWire.CONTINUOUS)
        val sent = mutableListOf<GimbalWaypoint>()
        val runner = NativeGimbalProgramRunner({ now }, { delay, action -> tasks += (now + delay) to action },
            { sample }, { point, _ -> sent += point; true }, {})
        runner.start(GimbalProgram(start, GimbalWaypoint(0.0, -10.0, 1.0, 0.0), durationAB = 2.0)) {}
        while (sent.isEmpty() && tasks.isNotEmpty() && now < 5.0) {
            val next = tasks.minBy { it.first }
            tasks.remove(next)
            now = maxOf(now, next.first)
            sample = NativeGimbalFeedback(start, now, nativePitch = NativePitchWire.CONTINUOUS)
            next.second()
        }
        val native = assertNotNull(sent.firstOrNull()?.nativePitchDeg)
        assertTrue(native in 174.4..190.0 + 1e-9, "beside +174.4°, never wrapped below −170°: $native")
    }

    @Test
    fun levelPlansBesideTheLiveNativePitch() {
        // Display tilt +6° at native +177°: the horizon is a 6° look-down, native +183°.
        val pose = GimbalWaypoint(0.0, 6.0, 1.0, 177.0)
        val continuous = WorldLevelSnap.plan(6.0, pose, 0.0, NativePitchWire.CONTINUOUS)!!
        assertEquals(1830, nativeTenths(continuous.second))
        val wrapped = WorldLevelSnap.plan(6.0, pose, 0.0)!!
        assertEquals(-1770, nativeTenths(wrapped.second))
        assertNull(WorldLevelSnap.plan(6.0, pose.copy(nativePitchDeg = 200.0), 0.0, NativePitchWire.CONTINUOUS))
    }
}
