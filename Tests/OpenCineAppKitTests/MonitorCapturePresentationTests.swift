import Foundation
import OpenCineCore
import OpenCineCoreTestSupport
import Testing

@testable import OpenCineAppKit

/// SIMULATED descriptor and confirmation scenarios. Kotlin mirrors the same names.
@MainActor
@Suite struct MonitorCapturePresentationTests {
    @Test func commonExposureAndFocusLabelsPreserveTypedDomainValues() {
        let values: [SettingValue] = [
            .exposureCompensation(Rational(-1, 3)), .exposureCompensation(Rational(0, 1)),
            .exposureCompensation(Rational(2, 3)), .focusMode(.single), .focusMode(.continuous),
        ]
        let domain = SettingDomain(choices: values)
        let exposure = MonitorCapturePresentation.choices(.exposureCompensation, domain: domain)
        #expect(exposure.map(\.value) == Array(values.prefix(3)))
        #expect(exposure.map(\.label) == ["−0.3", "0.0", "+0.7"])
        let focus = MonitorCapturePresentation.choices(.focusMode, domain: domain)
        #expect(focus.map(\.value) == Array(values.suffix(2)))
        #expect(focus.map(\.label) == ["AF-S", "AF-C"])
        #expect(MonitorCapturePresentation.title(.exposureCompensation) == "EV")
        #expect(MonitorCapturePresentation.title(.focusMode) == "FOCUS")
    }

    @Test func apertureUsesTheCommonCapturePresentation() {
        #expect(MonitorCapturePresentation.title(.aperture) == "IRIS")
        #expect(MonitorCapturePresentation.label(.aperture(2.8)) == "f/2.8")
    }

    @available(macOS 14, *)
    @Test func absentReportDoesNotSelectTheFirstDrumDetent() async throws {
        let camera = FakeCameraSession(
            behavior: FakeCameraSession.lunaLike().behavior,
            device: FakeDevice(rawMode: 0x01, settings: [], recording: nil))
        await camera.cameraReportsStatus()
        let control = MonitorControlModel()
        control.bind(camera)
        #expect(await eventually { control.snapshot?.mode.isKnown == true })
        let field = try #require(control.captureField(.iso))
        #expect(field.selection == nil && field.label == nil)
        #expect(!field.choices.isEmpty)
        #expect(control.recordEditor() == nil)
        let hud = control.statusPresentation(elapsedSeconds: 0)
        #expect(hud.recording == nil && hud.elapsedSeconds == nil && hud.timecode == nil)
        #expect(hud.recordingAccessibilityLabel == "Recording state unknown")
    }

    @available(macOS 14, *)
    @Test func typedDetentsCoalesceWithoutChangingTheReportedValue() async throws {
        let clock = ManualClock()
        let camera = FakeCameraSession.lunaLike()
        await camera.cameraReportsStatus()
        let control = MonitorControlModel(sleep: { await clock.sleep($0) })
        control.bind(camera)
        #expect(await eventually { control.captureField(.iso)?.isEditable == true })
        let field = try #require(control.captureField(.iso))
        for iso in [400, 800] {
            let choice = try #require(field.choices.first { $0.value == .iso(.manual(iso)) })
            #expect(control.commit(choice, from: field))
        }
        #expect(control.captureField(.iso)?.label == "800")
        #expect(await camera.current.value(of: .iso).value == .iso(.manual(200)))
        await clock.tick(.milliseconds(120))
        #expect(
            await eventuallyAsync { await camera.wire == ["set \(SettingValue.iso(.manual(800)))"] }
        )
    }

    @available(macOS 14, *)
    @Test func changedDomainRetiresTheOpenCaptureField() async throws {
        let camera = FakeCameraSession.djiLike()
        await camera.cameraReportsStatus()
        let control = MonitorControlModel()
        control.bind(camera)
        #expect(await eventually { control.captureField(.shutter)?.isEditable == true })
        let field = try #require(control.captureField(.shutter))
        let choice = try #require(field.choices.last)
        await camera.cameraSwitchesMode(raw: 0x02)
        #expect(await eventually { control.captureField(.shutter)?.editor != field.editor })
        #expect(!control.commit(choice, from: field))
        #expect(await camera.wire.isEmpty)
    }

    @available(macOS 14, *)
    @Test func domainChangeDuringCoalescingRetiresTheQueuedEdit() async throws {
        let clock = ManualClock()
        let camera = FakeCameraSession.djiLike()
        await camera.cameraReportsStatus()
        let control = MonitorControlModel(sleep: { await clock.sleep($0) })
        control.bind(camera)
        #expect(await eventually { control.captureField(.shutter)?.isEditable == true })
        let field = try #require(control.captureField(.shutter))
        #expect(control.commit(try #require(field.choices.last), from: field))
        await camera.cameraSwitchesMode(raw: 0x02)
        #expect(await eventually { control.captureField(.shutter)?.editor != field.editor })
        await clock.tick(.milliseconds(120))
        #expect(await eventually { control.pending.isEmpty })
        #expect(await camera.wire.isEmpty)
    }

    @available(macOS 14, *)
    @Test func readOnlyStillShowsTheReportButCannotCommit() async throws {
        let camera = FakeCameraSession.lunaLike()
        await camera.cameraReportsStatus()
        let control = MonitorControlModel()
        control.bind(camera)
        #expect(await eventually { control.captureField(.iso)?.isEditable == true })
        let field = try #require(control.captureField(.iso))
        await camera.setAuthority(.readOnly)
        #expect(await eventually { control.captureField(.iso)?.isEditable == false })
        #expect(control.captureField(.iso)?.label == "200")
        #expect(!control.commit(try #require(field.choices.last), from: field))
        #expect(await camera.wire.isEmpty)
    }

    /// R-03: a body pass reads the same drum, built once per domain. The base rebuilt every Kelvin
    /// detent (up to a thousand, with a quadratic membership scan) on each read.
    @available(macOS 14, *)
    @Test func aFieldsDrumIsBuiltOncePerDomain() async throws {
        let camera = FakeCameraSession.lunaLike()
        await camera.cameraReportsStatus()
        let control = MonitorControlModel()
        control.bind(camera)
        #expect(await eventually { control.captureField(.whiteBalance) != nil })
        let first = try #require(control.captureField(.whiteBalance)).choices
        let second = try #require(control.captureField(.whiteBalance)).choices
        #expect(first.count == 40, "Auto plus 39 detents")
        // Copies of one built array share its storage; a rebuild allocates new storage while
        // `first` is still alive, so equal addresses mean no rebuild.
        #expect(first.withUnsafeBufferPointer { $0.baseAddress } == second.withUnsafeBufferPointer { $0.baseAddress })
    }

    /// R-03: a thousand-step Kelvin domain keeps the explicit choices first and adds each detent once.
    @Test func aThousandStepKelvinDomainKeepsOrderWithoutDuplicates() {
        let explicit: [SettingValue] = [.whiteBalance(.auto), .whiteBalance(.kelvin(5600)), .whiteBalance(.preset("Sunny"))]
        let values = MonitorCapturePresentation.choices(
            .whiteBalance, domain: SettingDomain(choices: explicit, range: 1000...101_000, step: 100)
        ).map(\.value)
        #expect(values.count == 3 + 1000, "1001 detents, 5600 K already listed")
        #expect(Set(values).count == values.count)
        #expect(Array(values.prefix(3)) == explicit)
        #expect(values[3] == .whiteBalance(.kelvin(1000)) && values.last == .whiteBalance(.kelvin(101_000)))
    }

    /// R-03: the cache keys on everything a drum is built from, the key and the advertised domain
    /// (its listed values, range and step). A camera that re-advertises its list over the same
    /// range rebuilds the drum, and the shown value is read fresh on every pass, never cached.
    @available(macOS 14, *)
    @Test func aReadvertisedListRebuildsTheDrumAndTheShownValueStaysLive() async throws {
        var behavior = FakeCameraSession.lunaLike().behavior
        var presets = try #require(behavior.modes[0x01])
        let index = try #require(presets.descriptors.firstIndex { $0.key == .whiteBalance })
        presets.descriptors[index] = SettingDescriptor(.whiteBalance, domain: SettingDomain(
            choices: [.whiteBalance(.auto), .whiteBalance(.preset("Sunny"))], range: 2700...6500, step: 100))
        behavior.modes[0x02] = presets
        let camera = FakeCameraSession(
            behavior: behavior, device: FakeDevice(rawMode: 0x01, settings: [.whiteBalance(.kelvin(4000))]))
        await camera.cameraReportsStatus()
        let control = MonitorControlModel()
        control.bind(camera)
        #expect(await eventually { control.captureField(.whiteBalance)?.isEditable == true })
        let field = try #require(control.captureField(.whiteBalance))
        #expect(field.choices.count == 40 && field.label == "4000K")
        let choice = try #require(field.choices.first { $0.value == .whiteBalance(.kelvin(5600)) })
        #expect(control.commit(choice, from: field))
        let shown = try #require(control.captureField(.whiteBalance))
        #expect(shown.label == "5600K")
        #expect(shown.choices.withUnsafeBufferPointer { $0.baseAddress } == field.choices.withUnsafeBufferPointer { $0.baseAddress })
        await camera.cameraSwitchesMode(raw: 0x02)
        #expect(await eventually { control.captureField(.whiteBalance)?.choices.count == 41 })
        #expect(control.captureField(.whiteBalance)?.choices.prefix(2).map(\.label) == ["Auto", "Sunny"])
    }

    @available(macOS 14, *)
    @Test func kelvinDetentsHonorAnExplicitCameraStepAndBoundAllocation() {
        let values = MonitorCapturePresentation.choices(
            .whiteBalance,
            domain: SettingDomain(choices: [.whiteBalance(.auto)], range: 2000...2200, step: 50))
        #expect(values.map(\.label) == ["Auto", "2000K", "2050K", "2100K", "2150K", "2200K"])
        #expect(
            MonitorCapturePresentation.choices(
                .whiteBalance,
                domain: SettingDomain(range: 0...1_000_000, step: 1)
            ).isEmpty)
    }

    @available(macOS 14, *)
    @Test func recordAndWaitReturnsTheCameraReceiptAndPreservesExplicitRetries() async throws {
        let camera = FakeCameraSession.lunaLike()
        await camera.cameraReportsStatus()
        let control = MonitorControlModel()
        control.bind(camera)
        #expect(await eventually { control.recordEditor() != nil })
        let operation = Task { await control.recordAndWait(start: true) }
        #expect(await eventuallyAsync { await camera.wire == ["record-start"] })
        #expect(control.recordPending)
        await camera.advance(by: .seconds(3))
        #expect(await operation.value?.stage == .confirmed)
        #expect(!control.recordPending)
        #expect(await control.recordAndWait(start: true)?.stage == .confirmed)
        #expect(await camera.wire == ["record-start"])
    }

    @available(macOS 14, *)
    @Test func recordAndWaitDropsTheRetiredCamerasReceipt() async throws {
        let camera = FakeCameraSession.lunaLike()
        await camera.cameraReportsStatus()
        let control = MonitorControlModel()
        control.bind(camera)
        #expect(await eventually { control.recordEditor() != nil })
        let operation = Task { await control.recordAndWait(start: true) }
        #expect(await eventuallyAsync { await camera.wire == ["record-start"] })
        control.unbind()
        await camera.advance(by: .seconds(3))
        #expect(await operation.value == nil)
        #expect(await control.recordAndWait(start: true) == nil)
    }

    @available(macOS 14, *)
    @Test func recordingChangeRetiresTheApprovalWithoutSendingStop() async throws {
        let camera = FakeCameraSession.lunaLike()
        await camera.cameraReportsStatus()
        let control = MonitorControlModel()
        control.bind(camera)
        #expect(await eventually { control.recordEditor() != nil })
        let approval = try #require(control.recordEditor())
        #expect(!approval.recording)
        control.record(start: true)
        #expect(await eventuallyAsync { await camera.wire == ["record-start"] })
        await camera.advance(by: .seconds(3))
        #expect(await eventually { control.isRecording == true && !control.recordPending })
        #expect(!control.commitRecord(from: approval))
        #expect(await camera.wire == ["record-start"])
    }

    @available(macOS 14, *)
    @Test func approvalRetiresWithUnknownModeAndReplacement() async throws {
        let camera = FakeCameraSession.lunaLike()
        await camera.cameraReportsStatus()
        let control = MonitorControlModel()
        control.bind(camera)
        #expect(await eventually { control.recordEditor() != nil })
        let approval = try #require(control.recordEditor())
        await camera.cameraSwitchesMode(raw: 0xff)
        #expect(await eventually { !control.canCommitRecord(from: approval) })
        #expect(!control.commitRecord(from: approval))
        control.bind(camera)
        #expect(!control.commitRecord(from: approval))
        #expect(await camera.wire.isEmpty)
    }

    @available(macOS 14, *)
    @Test func recoveryEpochAndReplacementRetireTheApproval() async throws {
        let camera = FakeCameraSession.lunaLike()
        await camera.cameraReportsStatus()
        let control = MonitorControlModel()
        control.bind(camera)
        #expect(await eventually { control.recordEditor() != nil })
        let approval = try #require(control.recordEditor())
        let attempt = await camera.loseLink()
        #expect(await eventually { control.recordEditor() == nil })
        await camera.completeAttempt(attempt)
        #expect(await eventually { control.recordEditor() != nil })
        #expect(!control.commitRecord(from: approval))
        let nextApproval = try #require(control.recordEditor())
        control.bind(camera)
        #expect(await eventually { control.recordEditor() != nil })
        #expect(!control.commitRecord(from: nextApproval))
        #expect(await camera.wire.isEmpty)
    }
}
