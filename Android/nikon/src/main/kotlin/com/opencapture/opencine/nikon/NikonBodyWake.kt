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
 * with copy that says what is actually wrong. Bounded by dial count: each dial has its own
 * deadline, so the worst case is about 20 s with the defaults.
 */
object NikonBodyWake {
    /** Liveness dials before the body counts as silent. */
    const val DIALS: Int = 10

    /** Pause between two unanswered dials. */
    const val INTERVAL_MILLIS: Long = 500

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

    /** Dials [host] until it answers or [dials] dials went unanswered; cancellation propagates. */
    suspend fun awaitAnswer(
        host: String,
        dials: Int = DIALS,
        intervalMillis: Long = INTERVAL_MILLIS,
        isAlive: suspend (String) -> Boolean,
    ): Outcome {
        val bound = dials.coerceAtLeast(1)
        var made = 0
        while (made < bound) {
            made += 1
            if (isAlive(host)) return Outcome.Answered(made)
            if (made < bound) delay(intervalMillis)
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
        dial: suspend () -> T,
    ): T {
        try {
            return dial()
        } catch (failure: DialFailure) {
            if (!failure.wakeWorthy || !currentCoroutineContext().isActive) throw failure.underlying
            onWake()
            if (awaitAnswer(host, isAlive = isAlive) is Outcome.Silent) throw SilentException(deviceName)
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
