package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.CameraTimecode
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
     * the one already reported (a HUD shows whole seconds).
     */
    fun note(frameClockMs: Long, arrivalMs: Long, zone: TimeZone, fps: Int): CameraTimecode? {
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

        /**
         * Time-of-day timecode, non-drop. Frames count at the recording rate, halved above 30
         * (50 and 100 count 25s, 60 and 120 count 30s); unknown (0) counts 25s.
         */
        fun timecode(unixSeconds: Double, timeZoneSeconds: Int, fps: Int): CameraTimecode {
            var base = if (fps > 0) fps else 25
            while (base > 30) base /= 2
            val local = unixSeconds + timeZoneSeconds
            val whole = kotlin.math.floor(local)
            val second = Math.floorMod(whole.toLong(), 86_400L).toInt()
            val frame = minOf(base - 1, ((local - whole) * base).toInt())
            return CameraTimecode(second / 3600, (second / 60) % 60, second % 60, frame, dropFrame = false)
        }
    }
}
