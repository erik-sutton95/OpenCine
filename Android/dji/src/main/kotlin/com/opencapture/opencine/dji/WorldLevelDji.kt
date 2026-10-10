package com.opencapture.opencine.dji

import com.opencapture.opencine.motion.GimbalWaypoint
import com.opencapture.opencine.motion.LevelReading
import com.opencapture.opencine.motion.WorldLevel
import com.opencapture.opencine.motion.WorldLevelSnap
import com.opencapture.opencine.vocabulary.CameraCommands
import java.util.Locale
import kotlin.math.abs
import kotlin.math.sqrt

// The `0x04/0x05` attitude and the `0x04/0x14` snap payload; the level math is core motion's.

/**
 * Camera attitude against gravity from the `0x04/0x05` push. Mirrors iOS core
 * `WorldLevel.swift`: `@24…@39` float32 LE `x, w, y, z` of a unit quaternion
 * mapping world to camera (camera x forward, y up; gravity −y). Fit on 1,014
 * captured frames: tilt matches `−@20` (p50 0.02°). Roll sign is unconfirmed
 * on a rolled handle.
 */
fun WorldLevel.attitude(payload: ByteArray): WorldLevel.Quat? {
    if (payload.size < 40) return null
    fun f32(o: Int): Double {
        val bits = (payload[o].toInt() and 0xFF) or ((payload[o + 1].toInt() and 0xFF) shl 8) or
            ((payload[o + 2].toInt() and 0xFF) shl 16) or ((payload[o + 3].toInt() and 0xFF) shl 24)
        return Float.fromBits(bits).toDouble()
    }
    val q = WorldLevel.Quat(f32(28), f32(24), f32(32), f32(36))
    val norm = sqrt(q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z)
    if (!norm.isFinite() || abs(norm - 1) > 1e-3) return null
    return q
}

/** One `0x04/0x05` push; a payload without a valid attitude is ignored. */
fun LevelReading.ingest(payload: ByteArray, now: Double) {
    val q = WorldLevel.attitude(payload) ?: return
    ingest(q, now)
}

/** One `0x04/0x14` timed target to the nearest world target (mode `05` ignores roll). */
fun WorldLevelSnap.Companion.plan(tiltDeg: Double, pose: GimbalWaypoint, now: Double): Pair<WorldLevelSnap, ByteArray>? {
    val move = move(tiltDeg, pose) ?: return null
    val payload = CameraCommands.gimbalTimedTarget(pose.yawDeg, roundAway(move.nativePitchDeg * 10) / 10, move.duration)
        ?: return null
    return WorldLevelSnap(move.target, now + move.duration + WorldLevelSnap.SETTLE_GRACE) to payload
}

fun WorldLevelSnap.Companion.failureNote(errorDeg: Double?): String =
    if (errorDeg == null) WorldLevelSnap.NO_LEVEL_DATA else String.format(Locale.ROOT, "Couldn't level: %.1f° off", errorDeg)

/** Swift `.rounded()`: half away from zero (Kotlin `round` is half-even). */
private fun roundAway(value: Double): Double = Math.copySign(kotlin.math.floor(abs(value) + 0.5), value)
