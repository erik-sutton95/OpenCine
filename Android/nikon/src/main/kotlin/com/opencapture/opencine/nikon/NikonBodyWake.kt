package com.opencapture.opencine.nikon

import kotlinx.coroutines.delay

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

    /** Progress copy while the dials run. */
    fun wakingMessage(deviceName: String): String = "Waiting for ${camera(deviceName)} to answer on the network…"

    /** Failure copy for a body that stayed silent: the two real causes, never a socket timeout. */
    fun silentMessage(deviceName: String): String =
        "${camera(deviceName).replaceFirstChar(Char::uppercaseChar)} didn't answer on this network. If it is asleep, " +
            "wake it (half-press the shutter), check it is on the same Wi‑Fi as this device, then try again."

    private fun camera(deviceName: String): String = deviceName.trim().ifEmpty { "the camera" }
}
