package com.opencapture.opencine.relay

import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RelayPeerOwnerTest {
    private val start = 100_000L

    @Test
    fun refusedJoinCannotClaimParkedControlOrReceiveProtectedBytes() {
        val control = RelayHostControl()
        val first = UUID.randomUUID()
        control.register(first, "First", true)
        control.introduce(first, RelayPeerHello(1, "First", watcherID = "saved"), true, start)
        assertTrue(control.request(first, true))
        assertTrue(control.grantPending())
        val retiring = assertNotNull(control.admission(first))
        control.drop(first, start)

        val replacement = UUID.randomUUID()
        val hello = RelayPeerHello(1, "Replacement", passcode = "wrong", watcherID = "saved")
        control.register(replacement, hello.hostName, false)
        assertEquals(true, RelayJoinPolicy.refusal(hello, RelayWireProfile.SHARED_MONITOR, "right", "version")?.passcodeRequired)
        assertFalse(control.introduce(replacement, hello, false, start + 1_000))
        assertFalse(control.request(replacement, true))
        assertNull(control.admission(replacement))
        assertFalse(control.admits(retiring))
        val delivery = RelayPeerDelivery()
        assertEquals(RelayPeerDelivery.FrameDecision.UNAVAILABLE, delivery.admitFrame(true, true, 2))
        assertFalse(delivery.admitState())
        val accepted = RelayPeerHello(1, "Replacement", passcode = "right", watcherID = "saved")
        assertNull(RelayJoinPolicy.refusal(accepted, RelayWireProfile.SHARED_MONITOR, "right", "version"))
        assertTrue(control.introduce(replacement, accepted, true, start + 2_000))
        assertEquals(replacement, control.holder)
        assertEquals("Replacement", control.holderName)
        assertNotNull(control.admission(replacement))
    }

    @Test
    fun joinComparesPasscodesTrimmedAndKeepsEverySavedForm() {
        fun refused(offered: String?, required: String): Boolean =
            RelayJoinPolicy.refusal(RelayPeerHello(1, "Watcher", passcode = offered, watcherID = "w"),
                RelayWireProfile.SHARED_MONITOR, required, "version")?.passcodeRequired == true
        // Saved before the shared rule: four digits (OpenZCine), free text of any length and
        // untrimmed (the iOS apps' hosts this watcher may join). Each still admits its watchers.
        for (saved in listOf("0000", "4821", "a", "ab1", "set pass", " padded ", "pässwörd\n", "🎬🎬")) {
            assertFalse(refused(saved, saved), saved)
            assertFalse(refused(RelayJoinPolicy.normalizedPasscode(saved), saved), saved)
            assertTrue(refused("other", saved), saved)
            assertTrue(refused(null, saved), saved)
        }
        assertFalse(refused(" 1234\t", "1234"))
        assertFalse(refused("1234", "\u00A01234\u2003"))
        assertTrue(refused("12 34", "1234"))
        assertEquals("\u001F1234", RelayJoinPolicy.normalizedPasscode("\u001F1234"))
        // Whitespace alone is an open broadcast, as the rule's empty entry is.
        assertFalse(refused(null, " \n"))
    }

    @Test
    fun versionAdmissionIsExplicitAndDoesNotReplaceDeployedPermissiveHost() {
        val hello = RelayPeerHello(99, "Peer")
        assertEquals(RelayJoinPolicy.Refusal("version", false),
            RelayJoinPolicy.refusal(hello, RelayWireProfile.SHARED_MONITOR, "", "version"))
        assertNull(RelayJoinPolicy.refusal(hello, RelayWireProfile.SHARED_MONITOR, "", "version", requiresVersionMatch = false))
    }

    @Test
    fun slowPeerHasIndependentDepthAndCannotBreakHealthyReferenceChain() {
        val slow = RelayPeerDelivery(true)
        val healthy = RelayPeerDelivery(true)
        assertEquals(RelayPeerDelivery.FrameDecision.SEND, slow.admitFrame(true, true, 2))
        assertEquals(RelayPeerDelivery.FrameDecision.SEND, slow.admitFrame(true, false, 2))
        assertEquals(RelayPeerDelivery.FrameDecision.SATURATED, slow.admitFrame(true, false, 2))
        assertTrue(slow.needsKeyframe)
        assertEquals(2, slow.inFlightFrames)
        repeat(20) {
            assertEquals(RelayPeerDelivery.FrameDecision.SEND, healthy.admitFrame(true, healthy.needsKeyframe, 2))
            healthy.completeFrame()
        }
        assertFalse(healthy.needsKeyframe)
        assertEquals(0, healthy.inFlightFrames)
        slow.completeFrame()
        assertEquals(RelayPeerDelivery.FrameDecision.NEEDS_KEYFRAME, slow.admitFrame(true, false, 2))
        assertEquals(RelayPeerDelivery.FrameDecision.SEND, slow.admitFrame(true, true, 2))
        assertFalse(slow.needsKeyframe)
        val quality = RelayPeerDelivery(true)
        repeat(4) { assertEquals(RelayPeerDelivery.FrameDecision.SEND, quality.admitFrame(true, it == 0, 4)) }
        assertEquals(RelayPeerDelivery.FrameDecision.SATURATED, quality.admitFrame(true, false, 4))
        assertTrue(quality.admitState())
        assertFalse(quality.admitState())
        quality.completeState()
        assertEquals(4, quality.inFlightFrames)
        assertTrue(quality.admitState())
    }

    @Test
    fun codecNegotiationAndRefusalRetirePictureAdmission() {
        val jpeg = RelayPeerDelivery(true)
        jpeg.acceptsHevc = false
        assertEquals(RelayPeerDelivery.FrameDecision.WRONG_CODEC, jpeg.admitFrame(true, true, 2))
        assertEquals(0, jpeg.inFlightFrames)
        assertTrue(jpeg.needsKeyframe)
        assertEquals(RelayPeerDelivery.FrameDecision.SEND, jpeg.admitFrame(false, true, 2, jpegOnly = true))
        jpeg.closing = true
        assertFalse(jpeg.readyForFrame(2))
        assertEquals(RelayPeerDelivery.FrameDecision.UNAVAILABLE, jpeg.admitFrame(false, true, 2))
        assertFalse(jpeg.admitState())
        val hevc = RelayPeerDelivery(true)
        assertEquals(RelayPeerDelivery.FrameDecision.WRONG_CODEC, hevc.admitFrame(false, true, 2, jpegOnly = true))
    }

    @Test
    fun expiryCannotRevokeSuccessorGrantAndExactDeadlineDoesNotRestoreOldInstall() {
        val control = RelayHostControl()
        val first = UUID.randomUUID()
        val second = UUID.randomUUID()
        control.register(first, "First", true)
        control.introduce(first, RelayPeerHello(1, "First", watcherID = "saved"), true, start)
        assertTrue(control.request(first, true) && control.grantPending())
        val expiry = assertNotNull(control.drop(first, start))
        assertFalse(control.expire(expiry, start + 19_999))
        control.register(second, "Second", true)
        assertTrue(control.request(second, true) && control.grantPending())
        assertFalse(control.expire(expiry, start + 20_000))
        assertEquals(second, control.holder)
        control.reclaim()
        assertFalse(control.expire(expiry, start + 21_000))
        control.resetSource()
        control.register(first, "First", true)
        control.introduce(first, RelayPeerHello(1, "First", watcherID = "saved"), true, start)
        assertTrue(control.request(first, true) && control.grantPending())
        val exactExpiry = assertNotNull(control.drop(first, start))
        control.register(second, "Second", true)
        assertFalse(control.introduce(second, RelayPeerHello(1, "Second", watcherID = "saved"), true, start + 20_000))
        assertTrue(control.expire(exactExpiry, start + 20_000))
        assertNull(control.holder)
        assertNull(control.holderName)
    }

    @Test
    fun revokedPeerAndSameIdentitySourceReplacementCannotDispatchOldCommand() {
        val control = RelayHostControl()
        val peer = UUID.randomUUID()
        val hello = RelayPeerHello(1, "Same label", watcherID = "saved")
        control.register(peer, hello.hostName, true)
        control.introduce(peer, hello, true, start)
        assertTrue(control.request(peer, true) && control.grantPending())
        val command = assertNotNull(control.admission(peer))
        assertTrue(control.admits(command))
        control.introduce(peer, hello, false, start)
        assertFalse(control.admits(command))
        assertNull(control.holder)
        assertNull(control.drop(peer, start))
        control.resetSource()
        control.register(peer, hello.hostName, true)
        control.introduce(peer, hello, true, start)
        assertTrue(control.request(peer, true) && control.grantPending())
        val replacement = assertNotNull(control.admission(peer))
        assertNotEquals(command.source, replacement.source)
        assertFalse(control.admits(command))
        var dispatched = 0
        if (control.admits(command)) dispatched += 1
        assertEquals(0, dispatched)
        control.resetSource()
        if (control.admits(replacement)) dispatched += 1
        assertEquals(0, dispatched)
        assertNull(control.pendingName)
    }

    @Test
    fun retiredAndDuplicateCompletionsCannotReleaseSuccessorStageCredit() {
        val stages = RelayBroadcastStages(2, 1)
        val first = assertNotNull(stages.admit(RelayBroadcastStages.Lane.ENCODING))
        assertNotNull(stages.admit(RelayBroadcastStages.Lane.ENCODING))
        val jpeg = assertNotNull(stages.admit(RelayBroadcastStages.Lane.JPEG))
        assertNull(stages.admit(RelayBroadcastStages.Lane.ENCODING))
        assertNull(stages.admit(RelayBroadcastStages.Lane.JPEG))
        assertTrue(stages.complete(first))
        assertFalse(stages.complete(first))
        val blocked = assertNotNull(stages.admit(RelayBroadcastStages.Lane.ENCODING))
        stages.replace()
        val successor = assertNotNull(stages.admit(RelayBroadcastStages.Lane.ENCODING))
        assertFalse(stages.admits(first.stage))
        assertFalse(stages.complete(blocked))
        assertFalse(stages.complete(jpeg))
        assertEquals(1, stages.inFlight(RelayBroadcastStages.Lane.ENCODING))
        assertEquals(0, stages.inFlight(RelayBroadcastStages.Lane.JPEG))
        assertTrue(stages.complete(successor))
        stages.close()
        assertFalse(stages.complete(successor))
        assertNull(stages.admit(RelayBroadcastStages.Lane.ENCODING))
        assertNull(stages.admit(RelayBroadcastStages.Lane.JPEG))
        assertFalse(stages.isActive)
    }

    @Test
    fun stopAndReentryUseRealLifetimeInsteadOfAddressOrName() {
        val lifetime = RelayConnectionLifetime()
        val first = lifetime.begin()
        assertTrue(lifetime.admits(first))
        lifetime.retire()
        assertFalse(lifetime.admits(first))
        val replacement = lifetime.begin()
        assertNotEquals(first, replacement)
        assertTrue(lifetime.admits(replacement))
        assertFalse(lifetime.admits(first))
    }

    @Test
    fun passiveBrowseChurnPreservesShieldAndRetiresOldWindows() {
        val index = RelayDiscoveryIndex<String>(RelayDiscoveryIndex.Order.NAME)
        val first = index.start()
        val plain = RelayDiscoveryRow("same", "Camera", "listing")
        val shield = RelayDiscoveryRow("same", "Camera", "txt", "192.168.1.20", false)
        assertTrue(index.replace(listOf(plain, plain), "list", first))
        assertTrue(index.replace(listOf(shield), "txt", first))
        assertEquals(1, index.results.size)
        assertEquals("txt", index.results[0].endpoint)
        assertEquals("192.168.1.20", index.results[0].servedCameraHost)
        assertFalse(index.results[0].isWatchable)
        assertTrue(index.replace(emptyList(), "list", first))
        assertEquals(1, index.results.size)
        assertFalse(index.results[0].isWatchable)
        assertTrue(index.replace(emptyList(), "txt", first))
        assertTrue(index.results.isEmpty())
        index.stop()
        assertFalse(index.replace(listOf(shield), "txt", first))
        val successor = index.start()
        assertTrue(index.replace(listOf(plain), "list", successor))
        assertFalse(index.replace(listOf(shield), "txt", first))
        assertEquals(1, index.results.size)
        assertEquals("listing", index.results[0].endpoint)
        assertTrue(index.results[0].isWatchable)
    }
}
