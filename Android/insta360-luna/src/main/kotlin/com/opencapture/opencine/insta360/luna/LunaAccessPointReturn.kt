package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.RecoveryAction
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive

/**
 * What returning a Luna to its own Wi-Fi came to (Swift `LunaAccessPointReturn`, same cases).
 * Multiview's close asks every camera it moved back onto its own access point; a camera that is not
 * back stays in the caller's cleanup record for a later try.
 */
sealed interface LunaAccessPointReturn {
    /** The camera accepted the switch to its own access point. */
    data object Returned : LunaAccessPointReturn {
        override val failure: ConnectionFailure? get() = null
    }

    /**
     * Not now: Bluetooth could not reach it, it is still switching its Wi-Fi, or it did not answer.
     * Trying again a little later may succeed.
     */
    data class Deferred(override val failure: ConnectionFailure) : LunaAccessPointReturn

    /**
     * Trying again now will not help: the camera did not authorize this phone (it declined, another
     * phone holds it, or it is no supported Luna) or refused the switch.
     */
    data class Failed(override val failure: ConnectionFailure) : LunaAccessPointReturn

    /** A deferred result: the caller may try again. */
    val isRetryable: Boolean get() = this is Deferred

    /** Why the camera is not back; null once it returned. */
    val failure: ConnectionFailure?

    companion object {
        /**
         * Up to [attempts] tries of [attempt], with [waitBetween] before each retry of a deferred
         * result (DJI `restoreCameraWiFiWithRetry`): the first returned or failed result ends it, and
         * the last deferred result is the answer when every try was deferred. Cancellation is
         * thrown, never reported as a result.
         */
        suspend fun retrying(
            attempts: Int = 3,
            waitBetween: suspend () -> Unit = { delay(3_000) },
            attempt: suspend () -> LunaAccessPointReturn,
        ): LunaAccessPointReturn {
            var tries = 0
            while (true) {
                currentCoroutineContext().ensureActive()
                tries += 1
                val result = attempt()
                if (!result.isRetryable || tries >= attempts.coerceAtLeast(1)) return result
                waitBetween()
            }
        }

        internal fun failure(reason: ConnectionFailure.Reason, code: String, message: String) = ConnectionFailure(
            reason, null, "Couldn’t return the camera to its Wi-Fi", message, listOf(RecoveryAction.Retry),
            "${LunaFailures.INTEGRATION.rawValue}.return.$code",
        )

        internal val notReachable = failure(
            ConnectionFailure.Reason.NotFound, "not-reachable",
            "The camera is not reachable over Bluetooth. Keep it turned on and nearby, then try again.",
        )
        internal val cameraBusy = failure(
            ConnectionFailure.Reason.Other, "camera-busy", "The camera is still switching its Wi-Fi. Wait a moment, then try again.",
        )
        internal val noAnswer = failure(
            ConnectionFailure.Reason.TimedOut, "no-answer", "The camera did not answer over Bluetooth. Keep it nearby, then try again.",
        )
        internal val notAuthorized = failure(
            ConnectionFailure.Reason.NotApproved, "not-authorized",
            "The camera did not approve this phone. Close the Insta360 app on other devices, approve the connection on the camera, then try again.",
        )
        internal val refused = failure(ConnectionFailure.Reason.Other, "refused", "The camera refused to switch back to its own Wi-Fi.")

        /** A port without Bluetooth (a test port) cannot move a camera, so it has nothing to return. */
        internal val unsupported = failure(
            ConnectionFailure.Reason.Unsupported, "unsupported", "Returning the camera to its own Wi-Fi needs Bluetooth on a phone.",
        )
    }
}

/** The camera did not approve this phone over Bluetooth (declined, timed out or held by another phone). */
internal class LunaNotApproved(message: String) : IllegalStateException(message)

/**
 * The camera's side of a return to its own Wi-Fi (Swift `LunaAccessPointRestore`): Bluetooth reaches
 * it, it authorizes this phone ([LunaBluetoothAuthorization], whose credential read names the
 * camera's region), and one SET_WIFI_MODE 147 on the same link asks it onto its access point. The
 * link always closes afterwards. Nothing else is sent: no capture, record or live request, so no
 * recording is stopped; and the phone joins no network.
 */
internal class LunaAccessPointRestore(
    /** Bluetooth reaches the camera; the authorization runs on that link and also carries the switch. */
    private val link: suspend () -> LunaBluetoothAuthorization,
    /** This phone's approval identity, as the authorization check sends it. */
    private val authBody: ByteArray,
    /** Ends the Bluetooth link; runs after every outcome. */
    private val close: () -> Unit,
) {
    /** The return's result. Throws only [CancellationException]. */
    suspend fun run(): LunaAccessPointReturn {
        try {
            val authorization = try {
                link()
            } catch (error: Exception) {
                rethrowCancellation(error)
                return LunaAccessPointReturn.Deferred(LunaAccessPointReturn.notReachable)
            }
            val reply = try {
                authorization.run(authBody).second
            } catch (error: Exception) {
                rethrowCancellation(error)
                // Final only when the camera itself said no (it did not approve this phone, or it is
                // no supported Luna). A Bluetooth link that dropped (the GATT callback fails the
                // channel), a camera still switching or one that did not answer may answer later.
                return when (error) {
                    is LunaWiFiBusy -> LunaAccessPointReturn.Deferred(LunaAccessPointReturn.cameraBusy)
                    is TimeoutCancellationException -> LunaAccessPointReturn.Deferred(LunaAccessPointReturn.noAnswer)
                    is LunaNotApproved, is LunaUnsupportedCamera -> LunaAccessPointReturn.Failed(LunaAccessPointReturn.notAuthorized)
                    else -> LunaAccessPointReturn.Deferred(LunaAccessPointReturn.notReachable)
                }
            }
            try {
                val region = runCatching { LunaStationWire.countryCode(reply) }.getOrNull()
                authorization.request(LunaStationWire.SET_WIFI_MODE, LunaStationWire.wifiMode(LunaStationWire.Mode.ACCESS_POINT, region), true)
            } catch (error: Exception) {
                rethrowCancellation(error)
                return when (error) {
                    is LunaWiFiBusy -> LunaAccessPointReturn.Deferred(LunaAccessPointReturn.cameraBusy)
                    is LunaRefused -> LunaAccessPointReturn.Failed(LunaAccessPointReturn.refused)
                    else -> LunaAccessPointReturn.Deferred(LunaAccessPointReturn.noAnswer)
                }
            }
            return LunaAccessPointReturn.Returned
        } finally {
            close()
        }
    }

    /** A real cancellation is thrown on; a timeout inside a step (also a cancellation) is a result. */
    private suspend fun rethrowCancellation(error: Exception) {
        currentCoroutineContext().ensureActive()
        if (error is CancellationException && error !is TimeoutCancellationException) throw error
    }
}
