#if os(iOS)
import Foundation
import OpenCineCoreTestSupport
import OpenCineGyro
import Testing

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
        fixture.feed(from: 10, through: 10.1)
        coordinator.appDidEnterBackground()
        #expect(!coordinator.isArmed)
        #expect(coordinator.setupSteps.isEmpty)
        await coordinator.waitForCameraWrites()
        #expect(fixture.camera.writes.last == ["ibis": "SPORT"])
        await coordinator.processPending()
        #expect(!coordinator.motionRunning)

        coordinator.setHostEligible(true)
        #expect(coordinator.isArmed)
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
