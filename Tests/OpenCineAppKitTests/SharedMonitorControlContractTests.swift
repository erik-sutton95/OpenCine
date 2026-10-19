import Foundation
import MonitorPresentation
import OpenCineCore
import OpenCineCoreTestSupport
import Testing

@testable import OpenCineAppKit

/// SIMULATED contracts shared by every live surface, including a new integration.
/// Kotlin mirrors the scenario names. Camera reports and command time are explicit.
@Suite(.enabled(if: sharedMonitorControlContractsSupported))
@MainActor
struct SharedMonitorControlContractTests {
    @Test func absentLiveFactsRemainUnknownInsteadOfStandbyOrSilence() async throws {
        guard #available(macOS 14, *) else { return }
        let camera = MonitorContractCameraFixture.camera(recording: nil)
        await camera.cameraReportsStatus()
        let control = MonitorControlModel()
        control.bind(camera)
        defer { control.unbind() }
        #expect(await eventually { control.snapshot?.mode.isKnown == true })
        let snapshot = try #require(control.snapshot)
        let status = control.statusPresentation(elapsedSeconds: 17)
        #expect(status.recording == nil && status.elapsedSeconds == nil && status.timecode == nil)
        #expect(status.recordingLabel == "--")
        #expect(status.recordingAccessibilityLabel == "Recording state unknown")
        #expect(snapshot.power.battery.value == nil)
        #expect(snapshot.storage.value == nil)
        #expect(snapshot.audioLevels.value == nil)
        #expect(control.recordEditor() == nil)
        #expect(await camera.wire.isEmpty)
    }

    @Test func measuredEmptyMediaAndSilentAudioRemainKnown() async throws {
        guard #available(macOS 14, *) else { return }
        let silence = AudioLevels(left: .init(level: -120), right: .init(level: -120))
        let camera = MonitorContractCameraFixture.camera(
            recording: false, batteryPercent: 0, freeBytes: 0, audioLevels: silence)
        await camera.cameraReportsStatus()
        let control = MonitorControlModel()
        control.bind(camera)
        defer { control.unbind() }
        #expect(await eventually { control.snapshot?.mode.isKnown == true })
        let snapshot = try #require(control.snapshot)
        #expect(control.statusPresentation().recording == false)
        #expect(control.statusPresentation().recordingLabel == "STBY")
        #expect(snapshot.power.battery.value == 0)
        #expect(snapshot.storage.value?.first?.freeBytes.value == 0)
        #expect(snapshot.audioLevels.value == silence)
        #expect(snapshot.audioLevels.value?.left.peak == nil)
        #expect(await camera.wire.isEmpty)
    }

    @Test func readOnlyDescriptorKeepsItsReportWithoutGrantingAWrite() async throws {
        guard #available(macOS 14, *) else { return }
        let camera = MonitorContractCameraFixture.camera(access: .readOnly)
        await camera.cameraReportsStatus()
        let control = MonitorControlModel()
        control.bind(camera)
        defer { control.unbind() }
        #expect(await eventually { control.captureField(.iso) != nil })
        let field = try #require(control.captureField(.iso))
        #expect(field.label == "200" && field.selection == .iso(.manual(200)))
        #expect(!field.isEditable && field.editor == nil)
        let choice = try #require(field.choices.first { $0.value == .iso(.manual(400)) })
        let accepted = control.commit(choice, from: field)
        #expect(!accepted)
        #expect(control.pending.isEmpty)
        #expect(await camera.wire.isEmpty)
    }

    @Test func absentSettingDomainDoesNotInventEditableDetents() async throws {
        guard #available(macOS 14, *) else { return }
        let camera = MonitorContractCameraFixture.camera(domain: nil)
        await camera.cameraReportsStatus()
        let control = MonitorControlModel()
        control.bind(camera)
        defer { control.unbind() }
        #expect(await eventually { control.captureField(.iso) != nil })
        let field = try #require(control.captureField(.iso))
        #expect(field.label == "200")
        #expect(field.choices.isEmpty && !field.isEditable)
        let accepted = control.commit(.init(value: .iso(.manual(400)), label: "400"), from: field)
        #expect(!accepted)
        #expect(control.pending.isEmpty)
        #expect(await camera.wire.isEmpty)
    }

    @Test func recoveryWithIdenticalValuesRetiresTheCapturedField() async throws {
        guard #available(macOS 14, *) else { return }
        let clock = ManualClock()
        let camera = MonitorContractCameraFixture.camera()
        await camera.cameraReportsStatus()
        let control = MonitorControlModel(sleep: { await clock.sleep($0) })
        control.bind(camera)
        defer { control.unbind() }
        #expect(await eventually { control.captureField(.iso)?.isEditable == true })
        let before = try #require(control.captureField(.iso))
        let attempt = await camera.loseLink()
        #expect(await eventually { control.captureField(.iso)?.isEditable == false })
        await camera.completeAttempt(attempt)
        #expect(await eventually { control.captureField(.iso)?.isEditable == true })
        let after = try #require(control.captureField(.iso))
        #expect(after.selection == before.selection && after.choices == before.choices)
        #expect(after.editor != before.editor)
        let choice = try #require(before.choices.first { $0.value == .iso(.manual(400)) })
        let staleAccepted = control.commit(choice, from: before)
        #expect(!staleAccepted)
        let currentAccepted = control.commit(choice, from: after)
        #expect(currentAccepted)
        await clock.tick(.milliseconds(120))
        #expect(await eventuallyAsync { await camera.wire == ["set \(choice.value)"] })
    }

    /// A write refused before it was sent still reaches the app's journal with its label and stage:
    /// the Luna Angle-mode Manual write left no trace in the field log (owner, 2026-10-19).
    @Test func aWriteRefusedBeforeSendingIsJournaled() async throws {
        guard #available(macOS 14, *) else { return }
        let clock = ManualClock()
        let camera = MonitorContractCameraFixture.camera()
        await camera.cameraReportsStatus()
        let control = MonitorControlModel(sleep: { await clock.sleep($0) })
        var journal: [(String, CommandStage)] = []
        control.onWriteFinished = { journal.append(($0, $1.stage)) }
        control.bind(camera)
        defer { control.unbind() }
        #expect(await eventually { control.captureField(.iso)?.isEditable == true })
        control.set(.iso(.manual(1600)), label: "ISO 1600")
        #expect(await eventually { clock.pendingSleeps == 1 })
        clock.advance(by: .milliseconds(120))
        #expect(await eventually { !journal.isEmpty })
        #expect(journal.first?.0 == "ISO 1600")
        #expect(journal.first?.1 == .rejected(.outOfDomain))
        #expect(await camera.wire.isEmpty)
    }

    @Test func replacementRetiresQueuedWorkWithoutBorrowingTheSuccessor() async throws {
        guard #available(macOS 14, *) else { return }
        let clock = ManualClock()
        let old = MonitorContractCameraFixture.camera()
        let next = MonitorContractCameraFixture.camera()
        await old.cameraReportsStatus()
        await next.cameraReportsStatus()
        let control = MonitorControlModel(sleep: { await clock.sleep($0) })
        control.bind(old)
        defer { control.unbind() }
        #expect(await eventually { control.captureField(.iso)?.isEditable == true })
        let oldField = try #require(control.captureField(.iso))
        let oldChoice = try #require(oldField.choices.first { $0.value == .iso(.manual(400)) })
        let oldAccepted = control.commit(oldChoice, from: oldField)
        #expect(oldAccepted)
        #expect(await eventually { clock.pendingSleeps == 1 })
        control.bind(next)
        #expect(await eventually { control.snapshot?.session == next.id })
        let nextField = try #require(control.captureField(.iso))
        #expect(nextField.selection == oldField.selection && nextField.choices == oldField.choices)
        let staleAccepted = control.commit(oldChoice, from: oldField)
        #expect(!staleAccepted)
        let nextChoice = try #require(nextField.choices.first { $0.value == .iso(.manual(800)) })
        let nextAccepted = control.commit(nextChoice, from: nextField)
        #expect(nextAccepted)
        #expect(await eventually { clock.pendingSleeps == 2 })
        clock.advance(by: .milliseconds(120))
        #expect(await eventuallyAsync { await next.wire == ["set \(nextChoice.value)"] })
        await old.cameraReportsStatus()
        #expect(control.snapshot?.session == next.id)
        #expect(await old.wire.isEmpty)
    }
}

enum MonitorContractCameraFixture {
    static func camera(
        access: SettingAccess = .readWrite,
        domain: SettingDomain? = SettingDomain(choices: [
            .iso(.manual(200)), .iso(.manual(400)), .iso(.manual(800)),
        ]),
        recording: Bool? = false, batteryPercent: Int? = nil, freeBytes: UInt64? = nil,
        audioLevels: AudioLevels? = nil
    ) -> FakeCameraSession {
        let mode = FakeMode(
            .init(role: .video, id: "contract.video", title: "SIMULATED"),
            [.init(.iso, access: access, domain: domain)], unsupported: [],
            timecodeCapability: .supported(.seconds), audioLevels: .supported)
        let behavior = FakeCameraBehavior(
            integration: .init("contract"), reportDelay: .seconds(3),
            observationTimeout: .seconds(5), recordWire: .explicit, modes: [1: mode])
        return FakeCameraSession(behavior: behavior,
            device: FakeDevice(rawMode: 1, settings: [.iso(.manual(200))],
                recording: recording, batteryPercent: batteryPercent,
                freeBytes: freeBytes, audioLevels: audioLevels))
    }
}

private let sharedMonitorControlContractsSupported: Bool = {
    if #available(macOS 14, *) { return true }
    return false
}()
