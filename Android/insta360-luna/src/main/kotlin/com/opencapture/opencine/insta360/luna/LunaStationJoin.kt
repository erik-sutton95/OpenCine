package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.ConnectionPhase as CorePhase
import com.opencapture.opencine.core.StationRoutes
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull

/** A station notification from the camera's Bluetooth link. */
internal sealed interface LunaStationEvent {
    /** 8215: the camera's Wi-Fi (re)started, as after a role switch. */
    data object WiFiStarted : LunaStationEvent
    /** 8232: the camera's answer to a join. */
    data class Result(val result: LunaStationWire.JoinResult) : LunaStationEvent
}

/** Reply 505: the camera is still switching its Wi-Fi role and refuses [code] until 8215. */
internal class LunaWiFiBusy(code: Int) : IllegalStateException("Camera Wi-Fi busy switching for command $code")

/**
 * The camera's side of a Wi-Fi or hotspot setup after it was asked into station role (Swift
 * `LunaStationJoin`): the join request and its result, as the official app runs it.
 *
 * Right after a role switch the camera can refuse the join with reply 505 (Wi-Fi busy switching);
 * the join is sent again once notification 8215 says its Wi-Fi started. Only the result for this
 * join's network and password counts, so a late result from an earlier attempt is ignored. A
 * missing or transient result (timeout, connect failed, no address) gets one more try. Waits use
 * coroutine time, so tests run them on virtual time.
 */
internal class LunaStationJoin(
    /** Sends the join (112) over the encrypted session; throws [LunaWiFiBusy] for reply 505. */
    private val send: suspend (ssid: String, password: String) -> Unit,
    private val events: ReceiveChannel<LunaStationEvent>,
    private val timing: Timing = Timing(),
) {
    /** The join's waits, in milliseconds. */
    data class Timing(
        /** How long the camera gets to answer a join (8232). */
        val resultMs: Long = 45_000,
        /** How long a busy camera gets to start its Wi-Fi (8215); the official app waits 38 s. */
        val wifiStartMs: Long = 38_000,
        /** After 8215, before the join is sent again (the official app's delay for some cameras). */
        val settleMs: Long = 2_000,
    )

    /** Joins [network] and returns the camera's result; throws [LunaStationFailure] otherwise. */
    suspend fun run(network: LunaStationNetwork): LunaStationWire.JoinResult {
        var busy = 0
        var retried = false
        while (true) {
            // Only what the camera says after this request counts: 8215 also follows the
            // credential read, when its access point wakes.
            while (events.tryReceive().isSuccess) { /* earlier */ }
            try {
                send(network.ssid, network.password)
            } catch (_: LunaWiFiBusy) {
                if (busy >= BUSY_LIMIT) throw LunaStationFailure(busyFailure())
                busy += 1
                waitForWiFiStart()
                delay(timing.settleMs)
                continue
            }
            val result = result(network)
            if (result == null) {
                if (!retried) { retried = true; continue }
                throw LunaStationFailure(failure(null, network))
            }
            val outcome = result.outcome
            if (outcome == LunaStationWire.JoinResult.Outcome.Joined) return result
            if (outcome is LunaStationWire.JoinResult.Outcome.Failed && outcome.transient && !retried) {
                retried = true
                continue
            }
            throw LunaStationFailure(failure(outcome, network))
        }
    }

    /** Waits for 8215, or for [Timing.wifiStartMs]; results seen meanwhile belong to no join. */
    private suspend fun waitForWiFiStart() {
        withTimeoutOrNull(timing.wifiStartMs) {
            while (events.receive() != LunaStationEvent.WiFiStarted) { /* not this wait's event */ }
        }
    }

    /** This join's result, skipping 8215 and results for another network or password; null in time. */
    private suspend fun result(network: LunaStationNetwork): LunaStationWire.JoinResult? =
        withTimeoutOrNull(timing.resultMs) {
            var answer: LunaStationWire.JoinResult? = null
            while (answer == null) {
                val event = events.receive()
                if (event is LunaStationEvent.Result && event.result.answers(network.ssid, network.password)) {
                    answer = event.result
                }
            }
            answer
        }

    internal companion object {
        /** Busy replies accepted before the join gives up. */
        const val BUSY_LIMIT = 2

        fun busyFailure(): ConnectionFailure = LunaFailures.failure(
            ConnectionFailure.Reason.JoinFailed, "station.camera-busy",
            "The camera is still switching its Wi-Fi. Wait a moment, then connect again.",
            CorePhase.JOINING_NETWORK,
        )

        /**
         * The setup's copy for a join that did not succeed ([outcome] null: no answer in time). A
         * setup without a password may be missing one, so that failure says to check it.
         */
        fun failure(outcome: LunaStationWire.JoinResult.Outcome?, network: LunaStationNetwork): ConnectionFailure {
            val ssid = network.ssid
            fun failed(reason: ConnectionFailure.Reason, code: String, message: String) =
                LunaFailures.failure(reason, code, message, CorePhase.JOINING_NETWORK)
            if (network.password.isEmpty() && outcome != LunaStationWire.JoinResult.Outcome.NetworkNotFound) {
                return failed(ConnectionFailure.Reason.JoinFailed, "station.check-password", StationRoutes.checkPasswordMessage(ssid))
            }
            return when (outcome) {
                null -> failed(
                    ConnectionFailure.Reason.TimedOut, "station.join-timeout",
                    "The camera did not join “$ssid” in time. Check that the network is in range, then connect again.",
                )
                LunaStationWire.JoinResult.Outcome.WrongPassword -> failed(
                    ConnectionFailure.Reason.JoinFailed, "station.wrong-password",
                    "The camera could not join “$ssid”: the password is wrong. Edit the setup and enter it again.",
                )
                LunaStationWire.JoinResult.Outcome.NetworkNotFound -> failed(
                    ConnectionFailure.Reason.JoinFailed, "station.network-not-found",
                    "The camera cannot see “$ssid”. Check the network name and bring the camera closer.",
                )
                is LunaStationWire.JoinResult.Outcome.Failed -> failed(
                    ConnectionFailure.Reason.JoinFailed, "station.join-failed.${outcome.code}",
                    "The camera could not join “$ssid”. Check the network, then connect again.",
                )
                LunaStationWire.JoinResult.Outcome.Joined -> error("A joined result is not a failure")
            }
        }
    }
}
