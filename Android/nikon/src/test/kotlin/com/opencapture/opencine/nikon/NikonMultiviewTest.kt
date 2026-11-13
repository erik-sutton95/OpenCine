package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.media.MonitorTransfer
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * Swift suite `NikonMultiviewTests`: the Nikon operations a Pocket-standard Multiview tile needs.
 * Scripted links and a manual clock; physical Nikon behavior is untested.
 */
class NikonMultiviewTest {
    private class LinkDown : Exception()

    /** One opened PTP link: which host it reached and the serial GetDeviceInfo reported. */
    private data class Link(val host: String, val serial: String?)

    /** The bodies on the network, every dial and close, and a manual clock that `sleep` advances. */
    private class Network {
        val connects = mutableListOf<String>()
        val closed = mutableListOf<String>()
        val sleeps = mutableListOf<Duration>()
        var now = MonotonicInstant.ZERO
        val serials = mutableMapOf<String, String?>()

        fun connect(host: String): Link {
            connects += host
            if (host !in serials) throw LinkDown()
            return Link(host, serials[host])
        }
    }

    private fun opener(network: Network) = NikonMemberOpener(
        now = { network.now },
        sleep = { network.sleeps += it; network.now += it },
        connect = { network.connect(it) },
        serialNumber = { it.serial },
        close = { network.closed += it.host },
    )

    private val serial = "3001234"
    private val device = NikonMulticamPolicy.device(serial)!!

    // Open a picked body

    @Test
    fun openReturnsTheBodyAndItsSerialDevice() = runTest {
        val network = Network().apply { serials["192.168.1.30"] = serial }
        val result = opener(network).open("192.168.1.30", members = emptySet(), hostsInUse = emptySet())
        assertEquals(Link("192.168.1.30", serial), result.link)
        assertEquals(device, result.device)
        assertEquals(listOf("192.168.1.30"), network.connects)
        assertTrue(network.closed.isEmpty() && network.sleeps.isEmpty())
    }

    /** A host a member or Live View holds is never dialled: a second Init drops its session. */
    @Test
    fun openRefusesAHostInUseWithoutDialling() = runTest {
        val network = Network().apply { serials["192.168.1.30"] = serial }
        val result = opener(network).open("192.168.1.30", members = emptySet(), hostsInUse = setOf(" 192.168.1.30"))
        assertEquals(NikonMemberOpenRefusal.HOST_IN_USE, result.refusal)
        assertTrue(network.connects.isEmpty())
    }

    @Test
    fun openClosesAndRefusesABodyAlreadyInTheGroup() = runTest {
        val network = Network().apply { serials["192.168.1.40"] = serial } // the member, under a new address
        val result = opener(network).open("192.168.1.40", members = setOf(device), hostsInUse = emptySet())
        assertEquals(NikonMemberOpenRefusal.ALREADY_MEMBER, result.refusal)
        assertEquals(listOf("192.168.1.40"), network.closed)
    }

    @Test
    fun openClosesAndRefusesADifferentBody() = runTest {
        val network = Network().apply { serials["192.168.1.30"] = "3009999" }
        val result = opener(network).open("192.168.1.30", expectedSerial = serial, members = emptySet(), hostsInUse = emptySet())
        assertEquals(NikonMemberOpenRefusal.DIFFERENT_BODY, result.refusal)
        assertEquals(listOf("192.168.1.30"), network.closed)
    }

    /** Unknown is not a pass: without a serial the group cannot tell this body from a member. */
    @Test
    fun openClosesAndRefusesABodyWithoutASerial() = runTest {
        val network = Network().apply { serials["192.168.1.30"] = " " }
        val result = opener(network).open("192.168.1.30", members = emptySet(), hostsInUse = emptySet())
        assertEquals(NikonMemberOpenRefusal.NO_IDENTITY, result.refusal)
        assertEquals(listOf("192.168.1.30"), network.closed)
    }

    /** The settle after a close or a failed dial; other hosts never wait. */
    @Test
    fun openWaitsTheReconnectSettleAfterAClose() = runTest {
        val network = Network().apply {
            serials["192.168.1.30"] = serial
            serials["192.168.1.31"] = "3005678"
        }
        val opener = opener(network)
        val first = opener.open("192.168.1.30", members = emptySet(), hostsInUse = emptySet()).link!!
        opener.close(first, "192.168.1.30")
        network.now += 200.milliseconds
        opener.open("192.168.1.31", members = emptySet(), hostsInUse = emptySet())
        assertTrue(network.sleeps.isEmpty())
        opener.open("192.168.1.30", members = emptySet(), hostsInUse = emptySet())
        assertEquals(listOf(1_000.milliseconds), network.sleeps)

        // Nothing answers at .50: the dial fails.
        assertFailsWith<LinkDown> { opener.open("192.168.1.50", members = emptySet(), hostsInUse = emptySet()) }
        runCatching { opener.open("192.168.1.50", members = emptySet(), hostsInUse = emptySet()) }
        assertEquals(listOf(1_000.milliseconds, NikonMemberTiming.RECONNECT_SETTLE), network.sleeps)
        assertEquals(1_200.milliseconds, NikonMemberTiming.RECONNECT_SETTLE)
    }

    // Auto LUT source (Android's Swift session already polls the tone properties)

    @Test
    fun recordingToneMapsTheSnapshotsTone() {
        val expected = mapOf(
            "SDR" to MonitorTransfer.REC709,
            "HLG" to MonitorTransfer.HDR,
            "N-Log" to MonitorTransfer.NLOG,
            "Log3G10" to MonitorTransfer.LOG3G10,
        )
        for ((label, transfer) in expected) {
            val tone = CameraPropertySnapshot(movieTone = label).recordingTone
            assertEquals(label, tone?.label)
            assertEquals(transfer, tone?.monitorTransfer)
        }
    }

    /** Unknown is null, never SDR. */
    @Test
    fun recordingToneIsUnknownForAnUnnamedTone() {
        assertNull(CameraPropertySnapshot().recordingTone)
        assertNull(CameraPropertySnapshot(movieTone = "Standard").recordingTone)
    }

    // Bounded member repair

    private fun at(milliseconds: Int) = MonotonicInstant.ZERO + milliseconds.milliseconds

    /** A caller-owned budget of [limit] attempts, counting every ask. */
    private class Budget(val limit: Int) {
        var asks = 0
        var used = 0
        fun begin(): Boolean {
            asks += 1
            if (used >= limit) return false
            used += 1
            return true
        }
    }

    /** A stream that stops on a live link restarts live view in place first: no re-Init. */
    @Test
    fun repairRestartsLiveViewInPlaceForAStall() {
        val repair = NikonMemberRepair()
        val budget = Budget(3)
        repair.frameMissed(at(0))
        repair.frameMissed(at(0))
        assertEquals(NikonMemberRepair.Step.None, repair.next(at(0), budget::begin))
        repair.frameMissed(at(0))
        assertEquals(3, NikonMemberRepair.MISSED_FRAMES_FOR_STALL)
        assertEquals(NikonMemberRepair.Step.RestartLiveView, repair.next(at(0), budget::begin))
        assertEquals(NikonMemberRepair.Step.None, repair.next(at(0), budget::begin), "one attempt in flight")
        repair.attemptSucceeded()
        // Still no picture after the restart: the link is gone, so the next rung reopens it.
        repeat(3) { repair.frameMissed(at(2_000)) }
        assertEquals(NikonMemberRepair.Step.Wait(at(3_200)), repair.next(at(2_000), budget::begin))
        assertEquals(NikonMemberRepair.Step.Reopen, repair.next(at(3_200), budget::begin))
        assertEquals(2, budget.used)
    }

    @Test
    fun repairReopensOnlyAfterTheSettle() {
        val repair = NikonMemberRepair()
        val budget = Budget(3)
        repair.linkLost(at(0))
        assertEquals(NikonMemberRepair.Step.Wait(at(1_200)), repair.next(at(500), budget::begin))
        assertEquals(0, budget.asks, "waiting costs no attempt")
        assertEquals(NikonMemberRepair.Step.Reopen, repair.next(at(1_200), budget::begin))
        assertEquals(1, budget.used)
    }

    @Test
    fun repairSpacesFailedReopens() {
        val repair = NikonMemberRepair()
        val budget = Budget(3)
        repair.linkLost(at(0))
        assertEquals(NikonMemberRepair.Step.Reopen, repair.next(at(1_200), budget::begin))
        repair.attemptFailed(at(3_000))
        assertEquals(NikonMemberRepair.Step.Wait(at(8_000)), repair.next(at(3_000), budget::begin))
        assertEquals(5.seconds, NikonMemberTiming.REOPEN_SPACING)
        assertEquals(NikonMemberRepair.Step.Reopen, repair.next(at(8_000), budget::begin))
    }

    /** The caller's budget decides every attempt; once it refuses, nothing asks again. */
    @Test
    fun repairAsksTheBudgetBeforeEveryAttempt() {
        val repair = NikonMemberRepair()
        val budget = Budget(2)
        repair.linkLost(at(0))
        assertEquals(NikonMemberRepair.Step.Reopen, repair.next(at(1_200), budget::begin))
        repair.attemptFailed(at(1_300))
        assertEquals(NikonMemberRepair.Step.Reopen, repair.next(at(6_300), budget::begin))
        repair.attemptFailed(at(6_400))
        val spent = NikonMemberRepair.Step.WaitForOperator(NikonMemberRepair.WaitReason.BUDGET_SPENT)
        assertEquals(spent, repair.next(at(11_400), budget::begin))
        assertEquals(spent, repair.next(at(20_000), budget::begin))
        assertEquals(3, budget.asks)
        repair.reset()
        assertEquals(NikonMemberRepair.Step.None, repair.next(at(20_000), budget::begin))
    }

    /** Another phone took the body: the tile waits for the operator without spending an attempt. */
    @Test
    fun repairWaitsForTheOperatorAfterATakeOver() {
        val repair = NikonMemberRepair()
        val budget = Budget(3)
        repair.linkLost(at(0))
        repair.takenOver()
        assertEquals(
            NikonMemberRepair.Step.WaitForOperator(NikonMemberRepair.WaitReason.TAKEN_OVER),
            repair.next(at(5_000), budget::begin),
        )
        assertEquals(0, budget.asks)
    }

    /** A picture ends the episode: a later stall starts at the first rung again. */
    @Test
    fun aFrameEndsTheEpisode() {
        val repair = NikonMemberRepair()
        val budget = Budget(5)
        repair.streamStalled(at(0))
        assertEquals(NikonMemberRepair.Step.RestartLiveView, repair.next(at(0), budget::begin))
        repair.attemptSucceeded()
        repair.frameArrived()
        assertEquals(NikonMemberRepair.Step.None, repair.next(at(100), budget::begin))
        repair.streamStalled(at(9_000))
        assertEquals(NikonMemberRepair.Step.RestartLiveView, repair.next(at(9_000), budget::begin))
    }
}
