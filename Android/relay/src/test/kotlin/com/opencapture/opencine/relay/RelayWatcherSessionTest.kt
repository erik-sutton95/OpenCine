package com.opencapture.opencine.relay

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

// SIMULATED: exact watcher decisions on manual host time; no decoder or device proof.
class RelayWatcherSessionTest {
    @Test fun nativePresentationAloneCountsPicturesAndRepeatedReportCountsOnce() {
        val owner = RelayWatcherSession(); owner.begin(0.0); owner.connected(0.0)
        assertTrue(owner.admitsFrame(null, 0.1))
        owner.presentedPicture(1001.0, 0.1); owner.presentedPicture(1001.0, 0.2); owner.presentedPicture(1002.0, 0.3)
        assertEquals(WatcherRelayRecovery.Action.NONE, owner.tick(1.0)); assertEquals(2, owner.status.receivedFPS)
        assertEquals(WatcherRelayRecovery.Action.NONE, owner.tick(2.0)); assertEquals(0, owner.status.receivedFPS)
    }
    @Test fun stateTrafficCannotMasqueradeAsPictureAndThreeSecondWaitRemains() {
        val owner = RelayWatcherSession(); owner.begin(0.0); owner.connected(0.0); owner.receivedState(2.5)
        assertEquals(WatcherRelayRecovery.Action.NONE, owner.tick(2.99)); assertFalse(owner.status.waitingForPicture)
        assertEquals(WatcherRelayRecovery.Action.NONE, owner.tick(3.0)); assertTrue(owner.status.waitingForPicture)
        owner.receivedState(7.0); owner.receivedState(9.0)
        assertEquals(WatcherRelayRecovery.Action.NONE, owner.tick(10.0)); assertEquals(RelayWatcherPhase.Reconnecting(1), owner.status.phase)
        assertEquals(WatcherRelayRecovery.Action.RECONNECT, owner.tick(11.0))
    }
    @Test fun controlRequestExpiresAtFifteenSecondsAndLeaseReplyClearsIt() {
        val owner = RelayWatcherSession(); owner.begin(0.0); owner.connected(0.0)
        assertTrue(owner.requestControl(0.0)); assertFalse(owner.requestControl(0.1))
        for (now in 1..14) { owner.presentedPicture(now.toDouble(), now.toDouble()); owner.tick(now.toDouble()) }
        assertTrue(owner.status.controlRequested)
        owner.presentedPicture(15.0, 15.0); owner.tick(15.0)
        assertFalse(owner.status.controlRequested); assertTrue(owner.requestControl(15.0))
        owner.receivedControl(15.1); assertFalse(owner.status.controlRequested)
    }
    @Test fun retryDelayAndMaximumRetriesRemainOneTwoFourAndThree() {
        val owner = RelayWatcherSession(); owner.begin(0.0); owner.connected(0.0); var now = 0.0
        for ((index, delay) in listOf(1.0, 2.0, 4.0).withIndex()) {
            assertEquals(WatcherRelayRecovery.Action.NONE, owner.disconnected(now))
            assertEquals(RelayWatcherPhase.Reconnecting(index + 1), owner.status.phase)
            assertEquals(WatcherRelayRecovery.Action.NONE, owner.tick(now + delay - 0.001))
            assertEquals(WatcherRelayRecovery.Action.RECONNECT, owner.tick(now + delay))
            now += delay; owner.beginConnection(); owner.connected(now); now += 0.1
        }
        assertEquals(WatcherRelayRecovery.Action.EXHAUSTED, owner.disconnected(now))
        owner.fail("exhausted"); assertEquals(WatcherRelayRecovery.Action.NONE, owner.tick(now + 100))
        assertEquals(RelayWatcherPhase.Failed("exhausted"), owner.status.phase)
    }
    @Test fun frameFreshnessResetsOnlyForTheNewConnection() {
        val owner = RelayWatcherSession(); owner.begin(0.0); owner.connected(0.0)
        assertTrue(owner.admitsFrame(100.0, 20.0)); assertTrue(owner.admitsFrame(100.25, 21.0))
        assertFalse(owner.admitsFrame(100.25, 21.01)); owner.beginConnection()
        assertTrue(owner.admitsFrame(100.25, 21.01)); assertTrue(owner.admitsFrame(null, 999.0))
    }
    @Test fun terminalDenialAndLeaveCannotRetryOrKeepPendingControl() {
        val owner = RelayWatcherSession(); owner.begin(0.0); owner.connected(0.0); assertTrue(owner.requestControl(0.0))
        owner.denied(true, "passcode"); assertFalse(owner.active); assertFalse(owner.status.controlRequested)
        assertEquals(RelayWatcherPhase.NeedsPasscode, owner.status.phase)
        assertEquals(WatcherRelayRecovery.Action.NONE, owner.tick(100.0)); assertFalse(owner.requestControl(100.0))
        owner.begin(100.0); owner.connected(100.0); owner.disconnected(100.0); owner.leave()
        assertEquals(WatcherRelayRecovery.Action.NONE, owner.tick(200.0)); assertEquals(RelayWatcherPhase.Idle, owner.status.phase)
    }
}
