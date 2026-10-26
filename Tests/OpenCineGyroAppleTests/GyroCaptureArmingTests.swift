#if os(iOS)
import Foundation
import OpenCineCoreTestSupport
import OpenCineGyro
import Testing
import UIKit

@testable import OpenCineGyroApple

@MainActor @Suite("Gyro session arming")
struct GyroCaptureArmingTests {
    private static let sport = GyroStabilizationState(values: ["ibis": "SPORT"], lensHasVRSwitch: true)

    /// An enabled, loaded coordinator connected to a camera reporting SPORT stabilization.
    private func armed(
        _ fixture: GyroCoordinatorFixture, recording: Bool = false
    ) async -> GyroCaptureCoordinator {
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        fixture.camera.connect(stabilization: Self.sport, recording: recording, at: fixture.clock.time)
        await coordinator.waitForCameraWrites()
        return coordinator
    }

    @Test func armingWithIbisOnShowsTheStabilizationStepFirst() async {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = await armed(fixture)
        #expect(coordinator.isArmed)
        #expect(coordinator.motionRunning)
        #expect(coordinator.setupSteps.first == .stabilization(lensHasVRSwitch: true))
        #expect(coordinator.setupSteps.contains(.calibration(hasSavedCalibration: false)))
        #expect(fixture.camera.writes.isEmpty)
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test func turnOffWritesOffAndClearsTheWarning() async {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = await armed(fixture)
        coordinator.setupTurnOffStabilization()
        await coordinator.waitForCameraWrites()
        #expect(fixture.camera.writes == [["ibis": "OFF"]])
        #expect(coordinator.pill.stabilizationWarning == false)
        #expect(coordinator.setupSteps == [.calibration(hasSavedCalibration: false)])
        #expect(fixture.preferences.pendingRestores.first?.saved == ["ibis": "SPORT"])
        #expect(coordinator.notice == nil)
    }

    @Test func keepItOnArmsWithTheWarningMark() async {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = await armed(fixture)
        coordinator.setupKeepStabilization()
        #expect(coordinator.isArmed)
        #expect(fixture.camera.writes.isEmpty)
        #expect(coordinator.pill.stabilizationWarning)
        #expect(coordinator.setupSteps == [.calibration(hasSavedCalibration: false)])
        fixture.feed(from: 10, through: 10.1)
        await coordinator.processPending()
        #expect(coordinator.pill == GyroPillState(kind: .armed, stabilizationWarning: true))
    }

    @Test func toggleOffRestoresTheSavedValue() async {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = await armed(fixture)
        coordinator.setupTurnOffStabilization()
        await coordinator.waitForCameraWrites()
        coordinator.enabled = false
        await coordinator.waitForCameraWrites()
        #expect(fixture.camera.writes.last == ["ibis": "SPORT"])
        #expect(fixture.preferences.pendingRestores.isEmpty)
        #expect(!coordinator.isArmed)
        #expect(coordinator.setupSteps.isEmpty)
        #expect(coordinator.pill.kind == .hidden)
    }

    @Test func linkDropOwesTheRestoreAcrossLaunches() async {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let first = await armed(fixture)
        first.setupTurnOffStabilization()
        await first.waitForCameraWrites()
        fixture.camera.send(.disconnected)
        #expect(!first.isArmed)
        #expect(fixture.camera.writes == [["ibis": "OFF"]])
        #expect(fixture.preferences.pendingRestores.count == 1)
        first.detachAdapter()

        let relaunched = fixture.coordinator()
        await relaunched.waitUntilLoaded()
        #expect(relaunched.enabled)
        fixture.camera.connect(
            stabilization: .init(values: ["ibis": "OFF"], lensHasVRSwitch: true),
            at: fixture.clock.time)
        #expect(!relaunched.isArmed)
        await relaunched.waitForCameraWrites()
        #expect(fixture.camera.writes == [["ibis": "OFF"], ["ibis": "SPORT"]])
        #expect(fixture.preferences.pendingRestores.isEmpty)
        #expect(relaunched.isArmed)
        #expect(relaunched.setupSteps.first == .stabilization(lensHasVRSwitch: true))
        relaunched.enabled = false
        await relaunched.processPending()
    }

    @Test func connectingDuringRecordingDefersTheSheet() async throws {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = await armed(fixture, recording: true)
        #expect(coordinator.isArmed)
        #expect(coordinator.setupSteps.isEmpty)
        #expect(coordinator.ring == nil)
        fixture.feed(from: 10, through: 10.1)
        await coordinator.processPending()
        let take = try #require(coordinator.logs.first)
        #expect(take.active)
        #expect(take.descriptor.isPartial)
        #expect(coordinator.pill.kind == .recording)
        fixture.clock.time = 11
        fixture.record(false)
        #expect(coordinator.setupSteps.first == .stabilization(lensHasVRSwitch: true))
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test func backgroundingEndsTheSessionAndClosesTheSheet() async throws {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = await armed(fixture)
        coordinator.setupTurnOffStabilization()
        await coordinator.waitForCameraWrites()
        coordinator.beginCalibration()
        #expect(coordinator.ring == .intro)
        fixture.feed(from: 10, through: 10.1)
        coordinator.appDidEnterBackground()
        #expect(!coordinator.isArmed)
        #expect(coordinator.setupSteps.isEmpty)
        #expect(coordinator.ring == .invalidated(.connectionEnded))
        await coordinator.waitForCameraWrites()
        #expect(fixture.camera.writes.last == ["ibis": "SPORT"])
        await coordinator.processPending()
        #expect(!coordinator.motionRunning)

        coordinator.setHostEligible(true)
        #expect(coordinator.isArmed)
        #expect(coordinator.ring == nil)
        #expect(coordinator.setupSteps.first == .stabilization(lensHasVRSwitch: true))
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test func prepareForDisconnectAwaitsTheRestore() async {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = await armed(fixture)
        coordinator.setupTurnOffStabilization()
        await coordinator.waitForCameraWrites()
        await coordinator.prepareForDisconnect()
        #expect(!coordinator.isArmed)
        #expect(fixture.camera.writes.last == ["ibis": "SPORT"])
        #expect(fixture.preferences.pendingRestores.isEmpty)
        fixture.camera.send(.disconnected)
    }

    @Test func prepareForDisconnectGivesUpAfterTheTimeout() async {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = await armed(fixture)
        coordinator.setupTurnOffStabilization()
        await coordinator.waitForCameraWrites()
        fixture.camera.holdsWrites = true
        coordinator.restoreTimeout = .milliseconds(20)
        await coordinator.prepareForDisconnect()
        #expect(!coordinator.isArmed)
        #expect(fixture.camera.heldWriteCount == 1)
        #expect(fixture.camera.writes.last == ["ibis": "SPORT"])
        #expect(fixture.preferences.pendingRestores.count == 1)
        #expect(!coordinator.disconnecting, "A timed-out disconnect does not stick")
        fixture.camera.resolveHeldWrite(succeeded: true)
        await coordinator.waitForCameraWrites()
        #expect(fixture.preferences.pendingRestores.isEmpty)
    }

    /// Records the background task calls the coordinator makes.
    @MainActor final class BackgroundTaskLog {
        var begun = 0
        var ended = 0
    }

    private func recordBackgroundTasks(_ coordinator: GyroCaptureCoordinator) -> BackgroundTaskLog {
        let log = BackgroundTaskLog()
        coordinator.beginBackgroundTask = { _ in
            log.begun += 1
            return UIBackgroundTaskIdentifier(rawValue: 42)
        }
        coordinator.endBackgroundTaskHandler = { _ in log.ended += 1 }
        return log
    }

    @Test func backgroundingHoldsTheBackgroundTaskUntilTheRestoreLands() async {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = await armed(fixture)
        let log = recordBackgroundTasks(coordinator)
        coordinator.setupTurnOffStabilization()
        await coordinator.waitForCameraWrites()
        #expect(coordinator.motionRunning)
        fixture.camera.holdsWrites = true
        coordinator.appDidEnterBackground()
        #expect(log.begun == 1)
        await coordinator.processPending()
        #expect(!coordinator.motionRunning)
        #expect(log.ended == 0, "The save is done but the restore is still in flight")
        for _ in 0..<1_000 where fixture.camera.heldWriteCount < 1 { await Task.yield() }
        fixture.camera.resolveHeldWrite(succeeded: true)
        await coordinator.waitForCameraWrites()
        for _ in 0..<1_000 where log.ended == 0 { await Task.yield() }
        #expect(log.ended == 1)
        #expect(log.begun == 1)
        #expect(coordinator.backgroundTask == .invalid)
        #expect(fixture.preferences.pendingRestores.isEmpty)
    }

    @Test func backgroundingWithoutMotionStillCoversTheRestoreUpToTheTimeout() async throws {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        fixture.driver.unavailable = true
        let coordinator = await armed(fixture)
        let log = recordBackgroundTasks(coordinator)
        coordinator.setupTurnOffStabilization()
        await coordinator.waitForCameraWrites()
        #expect(!coordinator.motionRunning)
        fixture.camera.holdsWrites = true
        coordinator.restoreTimeout = .milliseconds(50)
        coordinator.appDidEnterBackground()
        #expect(log.begun == 1, "The restore alone takes a background task")
        #expect(log.ended == 0)
        for _ in 0..<200 where log.ended == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(log.ended == 1, "The timeout bounds the hold")
        #expect(fixture.camera.heldWriteCount == 1)
        fixture.camera.resolveHeldWrite(succeeded: true)
        await coordinator.waitForCameraWrites()
        #expect(log.ended == 1)
    }

    @Test func staleWriteFromAnEarlierConnectionIsIgnored() async {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = await armed(fixture)
        coordinator.setupTurnOffStabilization()
        await coordinator.waitForCameraWrites()
        fixture.camera.holdsWrites = true
        coordinator.restoreTimeout = .milliseconds(20)
        await coordinator.prepareForDisconnect()
        let stale = Array(coordinator.cameraWrites.values)
        #expect(stale.count == 1)
        fixture.camera.send(.disconnected)
        fixture.camera.connect(
            stabilization: .init(values: ["ibis": "OFF"], lensHasVRSwitch: true),
            at: fixture.clock.time)
        #expect(coordinator.cameraWrites.count == 2)
        #expect(!coordinator.isArmed)
        // The new restore reaches the camera when its write task first runs.
        for _ in 0..<1_000 where fixture.camera.heldWriteCount < 2 { await Task.yield() }
        #expect(fixture.camera.heldWriteCount == 2)

        fixture.camera.resolveHeldWrite(at: 0, succeeded: false)
        for write in stale { await write.value }
        #expect(coordinator.notice == nil)
        #expect(!coordinator.isArmed)
        #expect(fixture.preferences.pendingRestores.count == 1)

        fixture.camera.resolveHeldWrite(succeeded: true)
        await coordinator.waitForCameraWrites()
        #expect(coordinator.notice == nil)
        #expect(fixture.preferences.pendingRestores.isEmpty)
        #expect(coordinator.isArmed)
        #expect(coordinator.setupSteps.first == .stabilization(lensHasVRSwitch: true))
        coordinator.enabled = false
        await coordinator.waitForCameraWrites()
        await coordinator.processPending()
    }

    @Test func failedTurnOffShowsANotice() async {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = await armed(fixture)
        fixture.camera.acceptsWrites = false
        coordinator.setupTurnOffStabilization()
        await coordinator.waitForCameraWrites()
        #expect(coordinator.notice == .turnOffFailed)
        #expect(coordinator.pill.stabilizationWarning)
        #expect(coordinator.isArmed)
    }
}
#endif
