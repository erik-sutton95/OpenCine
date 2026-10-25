package com.opencapture.opencine.nikon

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

/**
 * The wake step before a saved Wi-Fi connect dials a body that discovery does not currently see
 * (Swift twin `NikonBodyWake` in OpenCineNikon; change one, change both).
 *
 * A router or hotspot setup the cameras list cannot see is dialled at its stored address blind;
 * when the body is asleep or off that network every PTP/IP attempt only learns so through a
 * command-connection timeout or "Host is down". This asks the network first with the cameras
 * list's own liveness dial (the presence port, never a PTP byte). The dials double as the wake: an
 * idle body's radio answers one in about 1.0-1.2 s once it is up. A silent body ends the attempt
 * with copy that says what is actually wrong.
 *
 * Paced by wall clock, one [SLOT_MILLIS] per dial: a dial that ends before its 1.5 s deadline
 * waits out the rest of its slot, so the wait is about 20 s with the defaults whatever the dials
 * do. Instant failures (a kernel that holds the host as unreachable after a failed address
 * resolution) used to collapse the wait to a few seconds, too short for an operator who wakes the
 * body by hand during it (hardware pass 2026-10-25, 1.11 and 3.7).
 */
object NikonBodyWake {
    /** Liveness dials before the body counts as silent. */
    const val DIALS: Int = 10

    /** Shortest pause between two unanswered dials. */
    const val INTERVAL_MILLIS: Long = 500

    /** Wall-clock share of one dial: its 1.5 s deadline plus [INTERVAL_MILLIS]. */
    const val SLOT_MILLIS: Long = 2_000

    /** What a dial's wake tells the progress surface (Swift `NikonBodyWake.Progress`). */
    enum class Progress { WAITING, ANSWERED }

    /** The pause after an unanswered dial that took [spentMillis]: the rest of its slot, at least the interval. */
    fun pauseAfter(spentMillis: Long, intervalMillis: Long = INTERVAL_MILLIS, slotMillis: Long = SLOT_MILLIS): Long =
        maxOf(intervalMillis, slotMillis - spentMillis)

    /**
     * The wake dials left after a failed connect that already took [spentMillis]: the connect's
     * own wait counts against the same budget, so the operator sees one wait of about [DIALS]
     * slots (Swift `dialsLeft`). At least one dial always runs.
     */
    internal fun dialsLeft(spentMillis: Long, dials: Int = DIALS, slotMillis: Long = SLOT_MILLIS): Int {
        if (slotMillis <= 0 || spentMillis <= 0) return dials.coerceAtLeast(1)
        return (dials - (spentMillis / slotMillis).toInt()).coerceAtLeast(1)
    }

    private fun monotonicMillis(): Long = System.nanoTime() / 1_000_000

    sealed interface Outcome {
        val dials: Int

        /** The body answered on dial [dials] (1-based). */
        data class Answered(override val dials: Int) : Outcome

        /** No dial reached the body. */
        data class Silent(override val dials: Int) : Outcome
    }

    /**
     * One TCP dial that failed before the PTP-IP handshake (Swift `NikonBodyWake.DialFailure`).
     * [wakeWorthy] is true only when the body did not answer at the link layer; a refusal proves
     * the host is up, so waking it cannot help.
     */
    class DialFailure(val underlying: Throwable, val wakeWorthy: Boolean) :
        Exception(underlying.message, underlying)

    /** The wake dials all went unanswered: the body is asleep or off this network. */
    class SilentException(val deviceName: String = "") : Exception(silentMessage(deviceName))

    /**
     * Dials [host] until it answers or [dials] dials went unanswered, one slot per dial on
     * [nowMillis] (a monotonic clock); cancellation propagates.
     */
    suspend fun awaitAnswer(
        host: String,
        dials: Int = DIALS,
        intervalMillis: Long = INTERVAL_MILLIS,
        slotMillis: Long = SLOT_MILLIS,
        nowMillis: () -> Long = ::monotonicMillis,
        isAlive: suspend (String) -> Boolean,
    ): Outcome {
        val bound = dials.coerceAtLeast(1)
        var made = 0
        while (made < bound) {
            made += 1
            val started = nowMillis()
            if (isAlive(host)) return Outcome.Answered(made)
            if (made < bound) delay(pauseAfter(nowMillis() - started, intervalMillis, slotMillis))
        }
        return Outcome.Silent(made)
    }

    /**
     * Runs [dial] once. When it fails with a wake-worthy [DialFailure], asks the network with
     * [awaitAnswer] and then dials exactly once more: a silent body, or a retry that is still
     * unreachable, ends with [SilentException]; a different second failure surfaces its own
     * error. There is no loop beyond that one retry (Swift twin `NikonBodyWake.dial`).
     */
    suspend fun <T> dial(
        host: String,
        deviceName: String = "",
        isAlive: suspend (String) -> Boolean,
        onWake: suspend () -> Unit = {},
        onWakeProgress: suspend (Progress) -> Unit = {},
        nowMillis: () -> Long = ::monotonicMillis,
        dial: suspend () -> T,
    ): T {
        val started = nowMillis()
        try {
            return dial()
        } catch (failure: DialFailure) {
            if (!failure.wakeWorthy || !currentCoroutineContext().isActive) throw failure.underlying
            onWake()
            onWakeProgress(Progress.WAITING)
            val left = dialsLeft(nowMillis() - started)
            if (awaitAnswer(host, dials = left, nowMillis = nowMillis, isAlive = isAlive) is Outcome.Silent) {
                throw SilentException(deviceName)
            }
            onWakeProgress(Progress.ANSWERED)
            try {
                return dial()
            } catch (retry: DialFailure) {
                // The single retry was unreachable too: surface the honest cause instead of a raw
                // socket sentence or a second wake.
                if (retry.wakeWorthy) throw SilentException(deviceName)
                throw retry.underlying
            }
        }
    }

    /** Progress copy while the dials run. */
    fun wakingMessage(deviceName: String): String = "Waiting for ${camera(deviceName)} to answer on the network…"

    /** Failure copy for a body that stayed silent: the two real causes, never a socket timeout. */
    fun silentMessage(deviceName: String): String =
        "${camera(deviceName).replaceFirstChar(Char::uppercaseChar)} didn't answer on this network. If it is asleep, " +
            "wake it (half-press the shutter), check it is on the same Wi‑Fi as this device, then try again."

    private fun camera(deviceName: String): String = deviceName.trim().ifEmpty { "the camera" }
}
