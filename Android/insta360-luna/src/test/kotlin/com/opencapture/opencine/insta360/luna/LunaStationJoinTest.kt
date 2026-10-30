package com.opencapture.opencine.insta360.luna

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * The camera's side of a Wi-Fi or hotspot setup (Swift `LunaStationJoinTests`): the join request
 * and its result over Bluetooth. A scripted camera answers each join; waits run on virtual time.
 */
class LunaStationJoinTest {
    private val network = LunaStationNetwork("Studio", "synthetic1", false)

    /** One answer per join request, in order. */
    private sealed interface Answer {
        /** Reply 505; [started] posts 8215 as the camera's Wi-Fi comes back. */
        data class Busy(val started: Boolean) : Answer
        /** Reply 200, then these notifications. */
        data class Accepted(val events: List<LunaStationEvent>) : Answer
    }

    private class Camera(vararg answers: Answer) {
        val events = Channel<LunaStationEvent>(16)
        private val script = ArrayDeque(answers.toList())
        var joins = 0
        fun send() {
            joins += 1
            when (val answer = script.removeFirstOrNull() ?: Answer.Accepted(emptyList())) {
                is Answer.Busy -> {
                    if (answer.started) events.trySend(LunaStationEvent.WiFiStarted)
                    throw LunaWiFiBusy(LunaStationWire.SET_WIFI_CONNECTION_INFO)
                }
                is Answer.Accepted -> answer.events.forEach { events.trySend(it) }
            }
        }
        fun join() = LunaStationJoin({ _, _ -> send() }, events)
    }

    private fun result(outcome: LunaStationWire.JoinResult.Outcome, password: String = "synthetic1") =
        LunaStationEvent.Result(LunaStationWire.JoinResult(outcome, "Studio", null, password))

    private val joined = LunaStationWire.JoinResult.Outcome.Joined

    @Test fun theCameraJoinsWhenItAnswersTheJoin() = runTest {
        val camera = Camera(Answer.Accepted(listOf(result(joined))))
        assertEquals(joined, camera.join().run(network).outcome)
        assertEquals(1, camera.joins)
    }

    @Test fun aCameraStillSwitchingItsWiFiIsAskedAgainOnceItsWiFiStarted() = runTest {
        // Reply 505 right after the role switch; 8215 when its Wi-Fi is back (the official app's flow).
        val camera = Camera(Answer.Busy(started = true), Answer.Accepted(listOf(result(joined))))
        assertEquals(joined, camera.join().run(network).outcome)
        assertEquals(2, camera.joins)
        assertEquals(2_000, currentTime, "the join waits only the settle time after 8215")
    }

    @Test fun aBusyCameraThatNeverSaysItsWiFiStartedIsAskedAgainAfterTheWait() = runTest {
        val camera = Camera(Answer.Busy(started = false), Answer.Accepted(listOf(result(joined))))
        assertEquals(joined, camera.join().run(network).outcome)
        assertEquals(2, camera.joins)
        assertEquals(40_000, currentTime, "38 s for 8215, then the settle time")
    }

    @Test fun aCameraThatStaysBusyEndsWithACameraBusyFailure() = runTest {
        val camera = Camera(Answer.Busy(true), Answer.Busy(true), Answer.Busy(true))
        val failure = assertFailsWith<LunaStationFailure> { camera.join().run(network) }
        assertEquals("com.opencapture.insta360.luna.station.camera-busy", failure.failure.code)
        assertEquals(3, camera.joins)
    }

    @Test fun aLateResultFromAnEarlierJoinIsNotThisJoinsAnswer() = runTest {
        // The first try went out without the password; its refusal arrives after this join.
        val camera = Camera(Answer.Accepted(listOf(result(LunaStationWire.JoinResult.Outcome.WrongPassword, ""), result(joined))))
        assertEquals(joined, camera.join().run(network).outcome)
    }

    @Test fun aTransientRefusalGetsOneMoreTry() = runTest {
        val camera = Camera(
            Answer.Accepted(listOf(result(LunaStationWire.JoinResult.Outcome.Failed(4)))),
            Answer.Accepted(listOf(result(joined))),
        )
        assertEquals(joined, camera.join().run(network).outcome)
        assertEquals(2, camera.joins)
    }

    @Test fun aWrongPasswordIsNotTriedAgain() = runTest {
        val camera = Camera(Answer.Accepted(listOf(result(LunaStationWire.JoinResult.Outcome.WrongPassword))))
        val failure = assertFailsWith<LunaStationFailure> { camera.join().run(network) }
        assertEquals("com.opencapture.insta360.luna.station.wrong-password", failure.failure.code)
        assertEquals(1, camera.joins)
    }

    @Test fun noAnswerGetsOneMoreTryThenTimesOut() = runTest {
        val camera = Camera(Answer.Accepted(emptyList()), Answer.Accepted(emptyList()))
        val failure = assertFailsWith<LunaStationFailure> { camera.join().run(network) }
        assertEquals("com.opencapture.insta360.luna.station.join-timeout", failure.failure.code)
        assertEquals(2, camera.joins)
        assertEquals(90_000, currentTime)
    }

    @Test fun aNetworkTheCameraCannotUseIsRefusedBeforeTheCameraIsMoved() {
        // Checked before the camera leaves its own Wi-Fi: the camera takes a 1 to 32 byte name
        // and an empty or 8 to 63 byte password.
        val unusable = listOf(
            LunaStationNetwork("Studio", "p".repeat(64), false),
            LunaStationNetwork("s".repeat(33), "synthetic1", false),
            LunaStationNetwork("Studio", "short", false),
        )
        for (candidate in unusable) {
            val failure = assertFailsWith<LunaStationFailure> { LunaStationJoin.check(candidate) }
            assertEquals("com.opencapture.insta360.luna.station.invalid-network", failure.failure.code)
        }
        for (candidate in listOf(network, LunaStationNetwork("Studio", "p".repeat(63), false), LunaStationNetwork("Studio", "", false))) {
            LunaStationJoin.check(candidate)
        }
    }

    @Test fun aSetupWithoutAPasswordThatFailsSaysToCheckThePassword() = runTest {
        val open = LunaStationNetwork("Studio", "", false)
        val refused = result(LunaStationWire.JoinResult.Outcome.Failed(2), "")
        val camera = Camera(Answer.Accepted(listOf(refused)), Answer.Accepted(listOf(refused)))
        val failure = assertFailsWith<LunaStationFailure> { camera.join().run(open) }
        assertEquals("com.opencapture.insta360.luna.station.check-password", failure.failure.code)
        assertTrue(failure.failure.message.contains("Check the Wi-Fi password"))
    }
}
