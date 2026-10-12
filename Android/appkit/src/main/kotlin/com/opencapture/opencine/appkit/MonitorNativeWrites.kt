package com.opencapture.opencine.appkit

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Latest-wins writes for a camera's native controls, the ones outside the common settings that
 * [MonitorControlModel] owns. While one write is on the wire, newer values wait per control and only
 * the last value of each is sent, so scrolling a drum never queues every detent. A refusal is reported
 * only while no newer value for that control waits: the operator has already moved on. Confine it to
 * the main thread; [scope] runs the writes.
 */
public class MonitorNativeWrites<K : Any, V : Any>(
    private val scope: CoroutineScope,
    /** Sends one value; throws when the camera refuses it. */
    private val write: suspend (K, V) -> Unit,
    /** Whether the camera already reports [V] for [K]; such a value is not sent again. */
    private val confirmed: (K, V) -> Boolean = { _, _ -> false },
    private val refused: (K, V, Exception) -> Unit,
) {
    private val desired = LinkedHashMap<K, V>()
    private var draining = false

    /** The control on the wire now; null while idle. */
    public var pending: K? by mutableStateOf(null)
        private set

    /** Queues [value] for [key], replacing any value of that control still waiting. */
    public fun submit(key: K, value: V) {
        desired[key] = value
        drain()
    }

    /** Whether a value for [key] is still waiting to be sent. */
    public fun isWaiting(key: K): Boolean = key in desired

    private fun drain() {
        if (draining) return
        draining = true
        scope.launch {
            try {
                while (desired.isNotEmpty()) {
                    val key = desired.keys.first()
                    val value = desired.remove(key) ?: continue
                    if (confirmed(key, value)) continue
                    pending = key
                    try {
                        write(key, value)
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Exception) {
                        if (key !in desired) refused(key, value, error)
                    }
                }
            } finally {
                pending = null
                draining = false
            }
        }
    }
}

/**
 * The app self-timer for stills: a countdown in whole seconds, then a run of releases, each waiting for
 * the previous capture to end. A press while it runs cancels the countdown or the rest of the run. The
 * countdown's sound and tally belong to the app: [start]'s `onTick` reports each second left and zero
 * once as the timer fires. Confine it to the main thread; [scope] runs the timer.
 */
public class MonitorPhotoTimer(
    private val scope: CoroutineScope,
    /** A capture still running after this long ends the run. */
    private val captureTimeoutMs: Long = 20_000,
) {
    private var job: Job? = null

    /** Seconds left in the countdown; null when no countdown runs. */
    public var remaining: Int? by mutableStateOf(null)
        private set

    public val isRunning: Boolean get() = job?.isActive == true

    /** Cancels a running countdown or run; false when nothing was running. */
    public fun cancel(): Boolean {
        val running = isRunning
        job?.cancel()
        job = null
        remaining = null
        return running
    }

    /**
     * Counts [seconds] down (none for 0) and then releases [shots] times. [capturing] reports whether
     * the previous release is still capturing.
     */
    public fun start(
        seconds: Int,
        shots: Int,
        capturing: () -> Boolean,
        release: () -> Unit,
        onTick: (Int) -> Unit = {},
    ) {
        cancel()
        job = scope.launch {
            try {
                if (seconds > 0) {
                    var left = seconds
                    remaining = left
                    onTick(left)
                    while (left > 0) {
                        delay(1_000)
                        left -= 1
                        remaining = left
                        onTick(left)
                    }
                    remaining = null
                }
                repeat(maxOf(1, shots)) { index ->
                    if (index > 0) {
                        var waited = 0L
                        while (capturing() && waited < captureTimeoutMs) {
                            delay(RELEASE_SPACING_MS)
                            waited += RELEASE_SPACING_MS
                        }
                        if (capturing()) return@launch
                    }
                    release()
                    delay(RELEASE_SPACING_MS)
                }
            } finally {
                remaining = null
            }
        }
    }

    private companion object {
        const val RELEASE_SPACING_MS = 150L
    }
}
