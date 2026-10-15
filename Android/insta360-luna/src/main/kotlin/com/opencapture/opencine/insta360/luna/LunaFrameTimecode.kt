package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.CameraTimecode
import com.opencapture.opencine.core.CameraTimecodeReading
import java.util.TimeZone

/**
 * Time-of-day timecode for Luna live frames (Swift `LunaFrameTimecode`). Frame stamps run on a
 * camera clock that does not follow its time of day, so frames are pinned to the phone clock by
 * their earliest arrival. With the camera clock synced to the phone (the backend's `syncClock` at
 * live start), that is the camera's timecode. One frame thread notes; any thread may reset.
 */
class LunaFrameTimecode {
    /** Phone clock minus frame clock in milliseconds; null until a frame arrives. */
    @Volatile var offsetMs: Long? = null
        private set
    @Volatile private var lastSecond: Long? = null

    /** Starts the pinning over, as after a link phase change. */
    fun reset() {
        offsetMs = null
        lastSecond = null
    }

    /**
     * The timecode of a frame stamped [frameClockMs] on the frame clock that arrived at [arrivalMs]
     * (unix milliseconds), with [zone]'s offset at that time of day, or null while its second is
     * the one already reported. The source knows whole seconds only (`TimecodePrecision.Seconds`),
     * so the value carries no frames.
     */
    fun note(frameClockMs: Long, arrivalMs: Long, zone: TimeZone): CameraTimecodeReading? {
        val seen = arrivalMs - frameClockMs - FRAME_LATENCY_MS
        val offset = minOf(offsetMs ?: seen, seen)
        offsetMs = offset
        val wall = frameClockMs + offset
        val second = Math.floorDiv(wall, 1_000L)
        if (second == lastSecond) return null
        lastSecond = second
        return timecode(wall / 1_000.0, zone.getOffset(wall) / 1_000)
    }

    /** Legacy clock synthesis for an explicitly known positive caller rate, never camera telemetry. */
    @Deprecated("Use the seconds-only reading API for camera observations")
    @Suppress("DEPRECATION")
    fun note(frameClockMs: Long, arrivalMs: Long, zone: TimeZone, fps: Int): CameraTimecode? {
        if (fps <= 0) return null
        val seen = arrivalMs - frameClockMs - FRAME_LATENCY_MS
        val offset = minOf(offsetMs ?: seen, seen)
        offsetMs = offset
        val wall = frameClockMs + offset
        val second = Math.floorDiv(wall, 1_000L)
        if (second == lastSecond) return null
        lastSecond = second
        return timecode(wall / 1_000.0, zone.getOffset(wall) / 1_000, fps)
    }

    companion object {
        /** Capture to phone delay of a live frame at best (frames land 90 to 200 ms after their stamp). */
        const val FRAME_LATENCY_MS = 90L

        /** Explicit legacy clock synthesis. The former unknown-rate guess is unavailable. */
        @Deprecated("Use the seconds-only reading API for camera observations")
        fun timecode(unixSeconds: Double, timeZoneSeconds: Int, fps: Int): CameraTimecode {
            require(fps > 0) { "Legacy clock synthesis requires a known positive rate" }
            var base = fps
            while (base > 30) base /= 2
            val local = unixSeconds + timeZoneSeconds
            val whole = kotlin.math.floor(local)
            val second = Math.floorMod(whole.toLong(), 86_400L).toInt()
            val frame = minOf(base - 1, ((local - whole) * base).toInt())
            return CameraTimecode(second / 3600, (second / 60) % 60, second % 60, frame, false)
        }

        /**
         * Time-of-day timecode in whole seconds. A frame field would be invented from the phone
         * clock, so there is none.
         */
        fun timecode(unixSeconds: Double, timeZoneSeconds: Int): CameraTimecodeReading {
            val second = Math.floorMod(kotlin.math.floor(unixSeconds + timeZoneSeconds).toLong(), 86_400L).toInt()
            return CameraTimecodeReading(second / 3600, (second / 60) % 60, second % 60)
        }
    }
}
