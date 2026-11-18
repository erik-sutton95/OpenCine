package com.opencapture.opencine.appkit

/**
 * The interface lock's rotation hold. While the monitor is
 * locked the screen keeps the orientation it had when the lock engaged, so an operator who
 * levels an inverted rig does not see the monitor flip. Unlocking releases it, and so does the
 * monitor going away.
 *
 * [V] is the platform's orientation fact: on Android the activity's previous orientation request
 * to restore, on iOS the interface orientation to hold.
 *
 * Swift mirror: `MonitorRotationHold` in `OpenCineAppKit`, same names.
 */
public class MonitorRotationHold<V : Any> {
    /** The captured value while the lock holds; null when free. */
    public var held: V? = null
        private set

    /**
     * Engaging the lock captures [current] once; while [current] is unknown (null) the capture
     * waits for the first known value. Later turns keep the capture; unlocking drops it.
     * Returns true when [held] changed.
     */
    public fun update(locked: Boolean, current: V?): Boolean {
        val previous = held
        if (!locked) held = null else if (held == null) held = current
        return held != previous
    }
}
