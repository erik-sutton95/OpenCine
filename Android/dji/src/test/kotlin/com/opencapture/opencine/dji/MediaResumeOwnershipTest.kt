package com.opencapture.opencine.dji

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

class MediaResumeOwnershipTest {
    @Test
    fun acceptedEnableDoesNotBecomeA350MillisecondPliLoop() {
        var enableSent = false
        var enables = 0
        repeat(10) {
            val action = MediaLiveResume.action(it + 1, false, true, false, enableSent)
            if (action == MediaLiveResume.Action.ENABLE_LIVE_VIEW) {
                enables += 1
                enableSent = true
            }
        }
        assertEquals(1, enables)
    }

    @Test
    fun expiredExitAndPictureBudgetsNeverIssueAnotherEnable() {
        assertNotEquals(MediaLiveResume.Action.ENABLE_LIVE_VIEW,
            MediaLiveResume.action(9, true, false, false))
        assertNotEquals(MediaLiveResume.Action.ENABLE_LIVE_VIEW,
            MediaLiveResume.action(2, false, true, false, enableSent = true, deadlineExpired = true,
                keyframeResendDue = true))
    }

    @Test
    fun productionRunnerResendsAtKeyframeCadenceThenExhaustsThePictureBudget() = runBlocking {
        var now = 0L
        val enables = mutableListOf<Long>()
        val result = MediaLiveResumeRunner.run(16_000, { now }, { true }, { false }, { false },
            exitPlayback = { now += 450; true }, enableLiveView = { enables += now; true },
            sleep = { now += it })
        assertEquals(MediaLiveResumeRunner.Result.EXHAUSTED, result)
        // First request at 630 ms, then one per KEYFRAME_RESEND_MS until the 16 s budget ends.
        assertEquals((0 until 8).map { 630L + it * LiveViewEnablePolicy.KEYFRAME_RESEND_MS }, enables)
        assertEquals(16_630L, now)
    }

    /** C5b (2026-10-19): the first IRAP after a 51 min gallery hit a dead codec session. */
    @Test
    fun unusableFirstAnswerIsRequestedAgainAndRestoresInsteadOfDroppingTheSession() = runBlocking {
        var now = 0L
        var enables = 0
        var usableAnswerAt: Long? = null
        val result = MediaLiveResumeRunner.run(16_000, { now }, { true }, { false },
            pictureFresh = { usableAnswerAt?.let { now >= it + 300 } ?: false },
            exitPlayback = { now += 450; true }, enableLiveView = {
                enables += 1
                if (enables == 2) usableAnswerAt = now
                true
            }, sleep = { now += it })
        assertEquals(MediaLiveResumeRunner.Result.RESTORED, result)
        assertEquals(2, enables)
    }

    @Test
    fun refusedResendAfterAKeptEnableRetriesAtTheLoopPace() = runBlocking {
        var now = 0L
        val attempts = mutableListOf<Long>()
        var first = true
        val result = MediaLiveResumeRunner.run(16_000, { now }, { true }, { false },
            pictureFresh = { now >= 3_500 },
            exitPlayback = { now += 450; true }, enableLiveView = {
                attempts += now
                if (first) {
                    first = false
                    true
                } else {
                    false
                }
            }, sleep = { now += it })
        assertEquals(MediaLiveResumeRunner.Result.RESTORED, result)
        // The refused 2.63 s resend must not push the next ask to 4.63 s.
        assertEquals(listOf(630L, 2_630L, 2_730L), attempts.take(3))
    }

    @Test
    fun pictureBudgetStartsAtTheFirstLiveViewRequestNotAtPlaybackExit() = runBlocking {
        var now = 0L
        var exits = 0
        var firstEnableAt: Long? = null
        val result = MediaLiveResumeRunner.run(16_000, { now }, { true }, { exits < 7 }, { false },
            exitPlayback = { exits += 1; now += 2_000; true },
            enableLiveView = { if (firstEnableAt == null) firstEnableAt = now; true },
            sleep = { now += it })
        assertEquals(MediaLiveResumeRunner.Result.EXHAUSTED, result)
        assertEquals(7, exits)
        assertEquals(firstEnableAt!! + 16_000, now)
    }

    @Test
    fun productionRunnerRestoresPictureWithoutResendingInsideTheKeyframeInterval() = runBlocking {
        var now = 0L
        var enables = 0
        val result = MediaLiveResumeRunner.run(16_000, { now }, { true }, { false }, { now >= 3_000 },
            exitPlayback = { now += 450; true }, enableLiveView = { enables += 1; true },
            sleep = { now += it })
        assertEquals(MediaLiveResumeRunner.Result.RESTORED, result)
        // Requested at 630 ms and again at 2630 ms; the picture lands at 3 s.
        assertEquals(2, enables)
    }

    @Test
    fun productionRunnerDoesNotEnableAfterPlaybackExitBudgetOrSupersession() = runBlocking {
        for (superseded in listOf(false, true)) {
            var now = 0L
            var current = true
            var exits = 0
            var enables = 0
            val result = MediaLiveResumeRunner.run(16_000, { now }, { current }, { true }, { false },
                exitPlayback = {
                    exits += 1
                    now += 450
                    if (superseded) current = false
                    false
                }, enableLiveView = { enables += 1; true }, sleep = { now += it })
            assertEquals(if (superseded) MediaLiveResumeRunner.Result.SUPERSEDED
                else MediaLiveResumeRunner.Result.EXHAUSTED, result)
            assertEquals(if (superseded) 1 else MediaLiveResume.MAX_EXIT_ATTEMPTS, exits)
            assertEquals(0, enables)
        }
    }

    @Test
    fun busyEnableGateRetriesAtOnceButAcceptedEnableWaitsForTheResendInterval() = runBlocking {
        var now = 0L
        var tries = 0
        var sent = 0
        val result = MediaLiveResumeRunner.run(16_000, { now }, { true }, { false }, { now >= 3_000 },
            exitPlayback = { now += 450; true }, enableLiveView = {
                tries += 1
                (tries >= 3).also { if (it) sent += 1 }
            }, sleep = { now += it })
        assertEquals(MediaLiveResumeRunner.Result.RESTORED, result)
        // Refused at 630 and 730 ms, accepted at 830 ms, resent once at 2830 ms.
        assertEquals(4, tries)
        assertEquals(2, sent)
    }
    @Test
    fun mediaReturnWaitsThroughMissingLinkAndStartsItsPictureBudgetAfterNegotiation() = runBlocking {
        var now = 0L
        var linkReady = false
        var repairBusy = true
        var enables = 0
        val ownsSlot = MediaLiveResumeRunner.awaitRepairSlot(
            isCurrent = { true }, repairBusy = { repairBusy }, sleep = {
                now += it
                if (now >= 20_000) { linkReady = true; repairBusy = false }
            })
        assertEquals(true, ownsSlot)
        assertEquals(true, linkReady)
        val result = MediaLiveResumeRunner.run(16_000, { now }, { linkReady }, { false }, { false },
            exitPlayback = { true }, enableLiveView = { enables += 1; true }, sleep = { now += it })
        assertEquals(MediaLiveResumeRunner.Result.EXHAUSTED, result)
        // The budget starts at the first request (20 180 ms), after negotiation and exit.
        assertTrue(now in 36_180L until 36_300L)
        assertEquals(8, enables)
    }

    @Test
    fun lostMediaOwnerWhileWaitingNeverClaimsThePictureBudget() = runBlocking {
        var current = true
        val ownsSlot = MediaLiveResumeRunner.awaitRepairSlot(
            isCurrent = { current }, repairBusy = { true }, sleep = { current = false })
        assertEquals(false, ownsSlot)
    }

    @Test
    fun retainedRepaintCannotCompleteMediaReturnWithoutFreshSource() = runBlocking {
        var now = 1_000L
        var enables = 0
        val startedAt = now
        val result = MediaLiveResumeRunner.run(16_000, { now }, { true }, { false },
            pictureFresh = {
                com.opencapture.opencine.vocabulary.RecoveryPictureProof.isFresh(
                    startedAt, now, presentedAt = now, accessUnitAt = startedAt - 1)
            }, exitPlayback = { true }, enableLiveView = { enables += 1; true }, sleep = { now += it })
        assertEquals(MediaLiveResumeRunner.Result.EXHAUSTED, result)
        assertEquals(8, enables)
    }

}
