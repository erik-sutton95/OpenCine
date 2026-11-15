package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.MulticamQualification
import com.opencapture.opencine.core.MulticamQualificationRefusal
import com.opencapture.opencine.core.NearbyCamera
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.StationCommissionOutcome
import com.opencapture.opencine.core.StationNetwork
import com.opencapture.opencine.core.StationRestoreResult
import com.opencapture.opencine.core.StationVerifyFinal
import com.opencapture.opencine.core.UnavailableReason
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Luna on a Multiview stage: which sightings join, the commission over Bluetooth (serial, station
 * move, the verification window) and the return to the access point. Swift mirror:
 * `LunaMultiviewTests`, same method names.
 */
class LunaMultiviewTest {
    private val sighting = NearbyCamera(
        id = "AA:BB:CC:DD:EE:01", name = "Luna A1B2", model = "Insta360 Luna Ultra", routes = setOf(RouteKind.CAMERA_ACCESS_POINT),
    )
    private val studio = StationNetwork("Studio", "synthetic1", false)

    private fun TestScope.commissioner(port: LunaStationPort) =
        LunaStationCommissioner(makePort = { port }, now = { testScheduler.currentTime })

    @Test
    fun anAvailableLunaJoinsWithItsPictureAndABusyOneIsNotOffered() {
        val policy = LunaMultiview.policy
        assertEquals(MulticamQualification.Qualified, policy.qualification(sighting, false))
        assertTrue(policy.hasPreview(sighting))
        assertTrue(policy.discoversByProbe)
        val busy = sighting.copy(availability = Availability.Unavailable(UnavailableReason.Busy))
        assertEquals(MulticamQualification.Refused(MulticamQualificationRefusal.OPERATION_UNAVAILABLE), policy.qualification(busy, false))
        assertEquals(MulticamQualification.Refused(MulticamQualificationRefusal.UNSUPPORTED_CONFIGURATION), policy.qualification(sighting, true))
    }

    @Test
    fun aSightingIsJournaledByItsPeripheral() {
        val record = LunaMultiview.record(sighting)
        assertEquals(sighting.id, record.id)
        assertEquals("Luna A1B2", record.name)
        assertNull(record.modelId)
        assertEquals("LUNA-A", LunaMultiview.serial(LunaMultiview.identity("LUNA-A")))
    }

    @Test
    fun theCommissionerAsksForApprovalAndHasNoExperimentalPath() = runTest {
        val commissioner = commissioner(FakeLunaStationPort(backgroundScope))
        assertTrue(commissioner.asksApprovalOnCamera)
        assertFalse(commissioner.joinsExperimentally)
        assertFalse(commissioner.scansNetworks)
    }

    @Test
    fun aCommissionProvesTheSerialAndMovesTheCamera() = runTest {
        val port = FakeLunaStationPort(backgroundScope).apply { serial = "LUNA-A" }
        val commission = commissioner(port).connect(sighting) {}
        assertEquals(listOf<FakeLunaStationPort.Step>(FakeLunaStationPort.Step.Authorize(sighting.id)), port.steps)
        val identity = commission.identity()
        assertContentEquals("LUNA-A".toByteArray(), identity)
        val progress = mutableListOf<String>()
        var asked = 0
        val outcome = commission.join(studio, identity, false, { progress += it }) { asked += 1; true }
        assertEquals(StationCommissionOutcome.VERIFIED, outcome)
        assertEquals(1, asked)
        assertEquals(
            listOf(FakeLunaStationPort.Step.Authorize(sighting.id), FakeLunaStationPort.Step.Move(LunaStationNetwork("Studio", "synthetic1", false))),
            port.steps,
        )
        assertEquals(listOf("Moving the camera to “Studio”…"), progress)
        assertFalse(port.bluetoothOpen)
    }

    @Test
    fun aCameraNotFoundYetIsAskedAgainWithinTheBudget() = runTest {
        val commission = commissioner(FakeLunaStationPort(backgroundScope)).connect(sighting) {}
        var asked = 0
        val outcome = commission.join(studio, ByteArray(0), false, {}) {
            asked += 1
            if (asked < 3) throw IllegalStateException("not found") else true
        }
        assertEquals(StationCommissionOutcome.VERIFIED, outcome)
        assertEquals(3, asked)
        assertEquals(2 * LunaStationCommissioner.VERIFY_INTERVAL_MS, testScheduler.currentTime)
    }

    @Test
    fun aCameraStillMissingAfterTheBudgetLeavesTheSearchToTheStage() = runTest {
        val commission = commissioner(FakeLunaStationPort(backgroundScope)).connect(sighting) {}
        val outcome = commission.join(studio, ByteArray(0), false, {}) { false }
        assertEquals(StationCommissionOutcome.JOINED, outcome)
        assertTrue(testScheduler.currentTime < LunaStationCommissioner.VERIFY_BUDGET_MS)
    }

    @Test
    fun aFinalVerificationEndsTheJoin() = runTest {
        val commission = commissioner(FakeLunaStationPort(backgroundScope)).connect(sighting) {}
        var asked = 0
        assertFailsWith<StationVerifyFinal> {
            commission.join(studio, ByteArray(0), false, {}) {
                asked += 1
                throw StationVerifyFinal(IllegalStateException("duplicate"))
            }
        }
        assertEquals(1, asked)
    }

    @Test
    fun aRefusedApprovalClosesBluetoothAndFailsTheAdd() = runTest {
        val port = FakeLunaStationPort(backgroundScope)
        port.authorizeFailure = LunaStationStepFailure(FakeLunaStationPort.failure(ConnectionFailure.Reason.NotApproved, "approval.declined"))
        assertFailsWith<LunaStationStepFailure> { commissioner(port).connect(sighting) {} }
        assertFalse(port.bluetoothOpen)
        assertTrue(port.steps.none { it is FakeLunaStationPort.Step.Move })
    }

    @Test
    fun closingACommissionClosesBluetooth() = runTest {
        val port = FakeLunaStationPort(backgroundScope)
        val commissioner = commissioner(port)
        commissioner.connect(sighting) {}
        assertTrue(port.bluetoothOpen)
        commissioner.closeCommissions()
        assertFalse(port.bluetoothOpen)
        assertEquals(FakeLunaStationPort.Step.Disconnect, port.steps.last())
    }

    @Test
    fun returnMapsEveryResult() = runTest {
        val record = LunaMultiview.record(sighting)
        val returned = FakeLunaStationPort(backgroundScope)
        assertEquals(StationRestoreResult.Restored, commissioner(returned).restoreAccessPoint(record))
        assertTrue(FakeLunaStationPort.Step.ReturnToAccessPoint(sighting.id) in returned.steps)

        val declined = FakeLunaStationPort(backgroundScope)
        val refusal = FakeLunaStationPort.failure(ConnectionFailure.Reason.NotApproved, "return.not-authorized")
        declined.returns += LunaAccessPointReturn.Failed(refusal)
        assertEquals(StationRestoreResult.Deferred(refusal.message), commissioner(declined).restoreAccessPoint(record))

        val away = FakeLunaStationPort(backgroundScope)
        val unreachable = FakeLunaStationPort.failure(ConnectionFailure.Reason.NotFound, "return.not-reachable")
        repeat(3) { away.returns += LunaAccessPointReturn.Deferred(unreachable) }
        assertEquals(StationRestoreResult.Deferred(unreachable.message), commissioner(away).restoreAccessPoint(record))
        assertEquals(3, away.steps.count { it == FakeLunaStationPort.Step.ReturnToAccessPoint(sighting.id) })
    }

    @Test
    fun aCancelledReturnStaysJournaled() = runTest {
        val gate = CompletableDeferred<Unit>()
        val port = FakeLunaStationPort(backgroundScope)
        port.during = { if (it is FakeLunaStationPort.Step.ReturnToAccessPoint) gate.await() }
        val pending = async { commissioner(port).restoreAccessPoint(LunaMultiview.record(sighting)) }
        runCurrent()
        assertTrue(FakeLunaStationPort.Step.ReturnToAccessPoint(sighting.id) in port.steps)
        pending.cancel()
        runCurrent()
        // Kotlin propagates the caller's cancellation; the coordinator keeps the camera journaled.
        assertTrue(pending.isCancelled)
    }

    @Test
    fun theScannerReportsEverySighting() = runTest {
        val other = sighting.copy(id = "AA:BB:CC:DD:EE:02")
        val scanner = LunaNearbyScanner { flowOf(listOf(sighting, other)) }
        val seen = mutableListOf<String>()
        assertTrue(scanner.waitUntilReady())
        scanner.scan { seen += it.id }
        assertEquals(listOf(sighting.id, other.id), seen)
    }
}
