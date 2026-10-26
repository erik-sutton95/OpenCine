#if os(iOS)
import Foundation
import OpenCineCoreTestSupport
import OpenCineGyro
import Testing
import UIKit

@testable import OpenCineGyroApple

@MainActor @Suite("Phone gyro capture logging")
struct GyroCaptureLoggingTests {
    @Test("Opt-in defaults off and is persisted")
    func optIn() async throws {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        fixture.connect()
        #expect(!coordinator.enabled)
        #expect(fixture.driver.starts == 0)
        coordinator.enabled = true
        #expect(fixture.driver.starts == 1)
        coordinator.enabled = false
        await coordinator.processPending()
        #expect(!coordinator.motionRunning)
        coordinator.enabled = true
        #expect(fixture.preferences.enabled)
        coordinator.enabled = false
        await coordinator.processPending()
        #expect(!fixture.preferences.enabled)
    }

    @Test("Only reported REC opens a take; repeated states do not duplicate it")
    func cameraTake() async throws {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        fixture.connect()
        fixture.feed(from: 10, through: 11.99)
        await coordinator.processPending()
        #expect(coordinator.logs.isEmpty)
        fixture.clock.time = 12
        fixture.record(true)
        fixture.record(true)
        await coordinator.processPending()
        #expect(coordinator.logs.count == 1)
        #expect(coordinator.logs.first?.active == true)
        #expect(coordinator.logs.first?.descriptor.cameraLabel == "Test camera")
        fixture.feed(from: 12, through: 12.99)
        fixture.clock.time = 13
        fixture.record(false)
        await coordinator.processPending()
        #expect(coordinator.logs.first?.active == true)
        fixture.feed(from: 13, through: 15)
        await coordinator.processPending()
        let summary = try #require(coordinator.logs.first?.summary)
        #expect(summary.termination == .normal)
        #expect(summary.sampleCount > 490)
        #expect(coordinator.logs.count == 1)
        #expect(coordinator.motionRunning)
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test("A delayed callback batch does not prune pre-roll before the REC event")
    func delayedStartBatch() async throws {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        fixture.connect()
        fixture.feed(from: 10, through: 11.99)
        await coordinator.processPending()
        fixture.clock.time = 12
        fixture.record(true)
        fixture.feed(from: 12, through: 12.1)
        await coordinator.processPending()
        coordinator.enabled = false
        await coordinator.processPending()
        let summary = try #require(coordinator.logs.first?.summary)
        #expect(summary.sampleCount == 211)
        #expect(abs(summary.duration - 2.1) < 0.0001)
    }

    @Test(
        "Interruption retains queued samples and releases the sensor",
        arguments: [GyroLogTermination.backgrounded, .disconnected, .disabled])
    func interruption(reason: GyroLogTermination) async throws {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        fixture.connect(recording: true)
        fixture.feed(from: 10, through: 10.2)
        switch reason {
        case .disabled: coordinator.enabled = false
        case .backgrounded: coordinator.appDidEnterBackground()
        default: fixture.camera.send(.disconnected)
        }
        if reason == .backgrounded { #expect(coordinator.backgroundTask.rawValue == 42) }
        await coordinator.processPending()
        let summary = try #require(coordinator.logs.first?.summary)
        #expect(summary.termination == reason)
        #expect(summary.sampleCount == 21)
        #expect(summary.isPartial)
        #expect(!coordinator.motionRunning)
        #expect(fixture.driver.buffer == nil)
        #expect(coordinator.backgroundTask == .invalid)
    }

    @Test("Rapid disable and enable finishes the prior take before rearming")
    func rapidRearm() async throws {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        fixture.connect(recording: true)
        fixture.feed(from: 10, through: 10.1)
        await coordinator.processPending()
        coordinator.enabled = false
        coordinator.enabled = true
        #expect(fixture.driver.starts == 1)
        await coordinator.processPending()
        #expect(fixture.driver.starts == 2)
        #expect(coordinator.logs.first?.summary?.termination == .disabled)
        await coordinator.processPending()
        #expect(coordinator.logs.contains { $0.active })
        coordinator.enabled = false
        await coordinator.processPending()
        #expect(!coordinator.motionRunning)
    }

    @Test("Ineligible sources cannot start motion, including a recording report")
    func ineligible() async {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator(hostEligible: false)
        coordinator.enabled = true
        fixture.connect(recording: true)
        await coordinator.waitUntilLoaded()
        #expect(!coordinator.motionRunning)
        #expect(fixture.driver.starts == 0)
        #expect(coordinator.logs.isEmpty)
        fixture.camera.send(.videoMode(false))
        coordinator.setHostEligible(true)
        #expect(!coordinator.motionRunning)
        #expect(fixture.driver.starts == 0)
    }

    @Test("A REC report during asynchronous recovery is retained")
    func reportBeforeLoad() async throws {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.enabled = true
        fixture.connect(recording: true)
        await coordinator.waitUntilLoaded()
        fixture.feed(from: 10, through: 10.1)
        await coordinator.processPending()
        #expect(coordinator.logs.first?.active == true)
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test("Unavailable sensors and lost callbacks produce a visible failure")
    func sensorFailures() async {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        fixture.driver.unavailable = true
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        fixture.connect()
        #expect(coordinator.failed)
        #expect(coordinator.notice == .sensorUnavailable)
        #expect(!coordinator.motionRunning)
        fixture.driver.unavailable = false
        coordinator.enabled = false
        coordinator.enabled = true
        #expect(!coordinator.failed)
        #expect(coordinator.motionRunning)
        fixture.clock.time = 13
        await coordinator.processPending()
        #expect(coordinator.failed)
        #expect(coordinator.notice == .sensorStalled)
        #expect(!coordinator.motionRunning)
    }

    @Test("A nonterminal sensor gap stays visible while the take continues")
    func liveGapWarning() async {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        fixture.connect(recording: true)
        fixture.feed(from: 10, through: 10.01)
        await coordinator.processPending()
        fixture.feed(from: 10.2, through: 10.21)
        await coordinator.processPending()
        #expect(coordinator.hasGapWarning)
        #expect(coordinator.motionRunning)
        #expect(!coordinator.failed)
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test("Disk failures abort file ownership and remain visible")
    func writeFailure() async {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let failing = FailingGyroStore()
        let coordinator = fixture.coordinator(store: failing)
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        fixture.connect(recording: true)
        fixture.feed(from: 10, through: 10.1)
        await coordinator.processPending()
        #expect(coordinator.failed)
        #expect(coordinator.notice == .saveFailed)
        #expect(!coordinator.motionRunning)
        #expect(await failing.aborted)
    }

    @Test("A repeated identical notice still bumps the notice token")
    func repeatedNoticeBumpsTheToken() async {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator(store: FailingGyroStore())
        await coordinator.waitUntilLoaded()
        let start = coordinator.noticeToken
        #expect(await coordinator.share([UUID()]).isEmpty)
        #expect(coordinator.notice == .shareFailed)
        #expect(coordinator.noticeToken == start + 1)
        #expect(await coordinator.share([UUID()]).isEmpty)
        #expect(coordinator.notice == .shareFailed)
        #expect(coordinator.noticeToken == start + 2)
        coordinator.clearNotice()
        #expect(coordinator.noticeToken == start + 2, "Clearing is not a new notice")
    }
}
#endif
