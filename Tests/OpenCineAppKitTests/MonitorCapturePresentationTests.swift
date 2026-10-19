import Foundation
import OpenCineCore
import MonitorPresentation
import OpenCineCoreTestSupport
import Testing

@testable import OpenCineAppKit

/// SIMULATED descriptor and confirmation scenarios. Kotlin mirrors the same names.
@MainActor
@Suite struct MonitorCapturePresentationTests {
    @Test func recordingReadoutsKeepExactCadenceAndUnknownFacts() throws {
        var snapshot = CameraSnapshot(session: CameraSessionID())
        #expect(MonitorCapturePresentation.recordingLabel(MonitorCapturePresentation.recordingFormat(snapshot)) == nil)
        snapshot.recordingFormat.dimensions = ObservedValue(try #require(CameraRecordingFormat.Dimensions(width: 3840, height: 2160)), origin: .cameraReported, at: .zero)
        snapshot.settings[.frameRate] = ObservedValue(.frameRate(Rational(24_000, 1_001)), origin: .cameraReported, at: .zero)
        snapshot.recordingFormat.profile = ObservedValue("I-Log", origin: .cameraReported, at: .zero)
        let format = MonitorCapturePresentation.recordingFormat(snapshot)
        #expect(MonitorCapturePresentation.recordingLabel(format) == "4K · 23.98p")
        #expect(format.codec == nil && format.profile == "I-Log")
        #expect(MonitorCapturePresentation.recordingLabel(CameraRecordingFormat(dimensions: format.dimensions)) == "4K")
        #expect(MonitorCapturePresentation.resolutionLabel(try #require(CameraRecordingFormat.Dimensions(width: 1080, height: 1920))) == "1080p 9:16")
    }

    /// Behavior audit PAA-255: the DJI 1:1 1080 format (0x69) read "1080p 1:1" in the standalone app.
    @Test func squareTenEightyReadsAsTenEightyP() throws {
        #expect(MonitorCapturePresentation.resolutionLabel(try #require(CameraRecordingFormat.Dimensions(width: 1080, height: 1080))) == "1080p 1:1")
        #expect(MonitorCapturePresentation.resolutionLabel(try #require(CameraRecordingFormat.Dimensions(width: 2160, height: 2160))) == "2160p 1:1")
    }

    /// Behavior audit PAA-221: the Custom white balance hold drum scrubs Kelvin only; leaving
    /// Custom for Auto takes the panel, as in the standalone apps.
    @available(macOS 14, *)
    @Test func customWhiteBalanceScrubKeepsKelvinOnly() {
        let choices: [SettingValue] = [.whiteBalance(.auto), .whiteBalance(.preset("daylight")),
            .whiteBalance(.kelvin(3200)), .whiteBalance(.kelvin(5600))]
        let field = MonitorCaptureField(key: .whiteBalance, title: "WB", selection: .whiteBalance(.kelvin(5600)),
            choices: choices.map { MonitorCaptureChoice(value: $0, label: MonitorCapturePresentation.label($0)) },
            editor: nil)
        #expect(field.kelvinScrub.choices.map(\.label) == ["3200K", "5600K"])
        #expect(field.kelvinScrub.selection == field.selection)
    }

    #if os(iOS)
    /// Behavior audit PAA-204: the ISO hold drum opened from a common field still stars the native ISO.
    @available(macOS 14, *)
    @Test func commonFieldHoldDrumCarriesTheStarredDetents() {
        let field = MonitorCaptureField(key: .iso, title: "ISO", selection: .iso(.manual(400)),
            choices: [100, 400, 800].map { MonitorCaptureChoice(value: .iso(.manual($0)), label: "\($0)") },
            editor: nil)
        let readout = MonitorOperatorLiveReadout<SettingKey, String>(id: .iso, title: "ISO", value: "400",
            field: field, marked: ["400"])
        #expect(readout.fieldSnapshot == MonitorReadoutSnapshot(title: "ISO", options: ["100", "400", "800"],
            selection: "400", marked: ["400"]))
    }
    #endif

    @Test func exposureProgramLabelsUseTheReportedProgram() {
        #expect(MonitorCapturePresentation.exposureProgram(.manual) == "M")
        #expect(MonitorCapturePresentation.exposureProgram(.automatic) == "A")
        #expect(MonitorCapturePresentation.exposureProgram(.isoPriority) == "I")
        #expect(MonitorCapturePresentation.exposureProgram(.shutterPriority) == "S")
        #expect(MonitorCapturePresentation.exposureProgram(.program) == "P")
    }

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

    /// An unreported readout is drawn as a dash but read as "Not set"; a reported one as drawn.
    @Test func unreportedReadoutsAreSpokenAsNotSet() {
        for drawn in ["--", "\u{2014}", ""] {
            #expect(MonitorCapturePresentation.spokenValue(drawn) == "Not set")
        }
        for drawn in ["1600", "Auto", "1/50", "AF-C", "\u{2212}0.3"] {
            #expect(MonitorCapturePresentation.spokenValue(drawn) == drawn)
        }
    }

    /// An unreported value with nothing to edit is inert; a report, an editor or a host action keeps it live.
    @Test func unreportedUneditableReadoutsAreInert() {
        #expect(MonitorCapturePresentation.readoutIsInert(reported: false, editable: false, quickEnabled: true, hasAction: false))
        #expect(MonitorCapturePresentation.readoutIsInert(reported: false, editable: true, quickEnabled: false, hasAction: false))
        #expect(MonitorCapturePresentation.readoutIsInert(reported: false, editable: nil, quickEnabled: false, hasAction: false))
        #expect(!MonitorCapturePresentation.readoutIsInert(reported: false, editable: true, quickEnabled: true, hasAction: false))
        #expect(!MonitorCapturePresentation.readoutIsInert(reported: true, editable: false, quickEnabled: false, hasAction: false))
        #expect(!MonitorCapturePresentation.readoutIsInert(reported: false, editable: false, quickEnabled: false, hasAction: true))
        #expect(!MonitorCapturePresentation.readoutIsInert(reported: false, editable: nil, quickEnabled: true, hasAction: false))
        guard #available(macOS 14, *) else { return }
        let unreported = MonitorCaptureField(key: .iso, title: "ISO", selection: nil, choices: [], editor: nil)
        #expect(MonitorCapturePresentation.readoutIsInert(value: "Not set", field: unreported, nativeEnabled: nil,
            quickEnabled: true, hasAction: false))
        let reported = MonitorCaptureField(key: .iso, title: "ISO", selection: .iso(.auto), choices: [], editor: nil)
        #expect(!MonitorCapturePresentation.readoutIsInert(value: "Auto", field: reported, nativeEnabled: nil,
            quickEnabled: true, hasAction: false))
        #expect(MonitorCapturePresentation.readoutIsInert(value: "--", field: nil, nativeEnabled: false,
            quickEnabled: true, hasAction: false))
        #expect(!MonitorCapturePresentation.readoutIsInert(value: "1600", field: nil, nativeEnabled: false,
            quickEnabled: true, hasAction: false))
    }

    /// A5-09: one frame-rate label for every integration; the NTSC family keeps its decimals.
    @Test func frameRateLabelsKeepTheExactRate() {
        let table: [(Rational, String)] = [
            (Rational(24000, 1001), "23.98"), (Rational(24), "24"), (Rational(25), "25"),
            (Rational(30000, 1001), "29.97"), (Rational(60000, 1001), "59.94"),
            (Rational(120000, 1001), "119.88"), (Rational(50), "50"),
        ]
        for (rate, label) in table {
            #expect(MonitorCapturePresentation.label(.frameRate(rate)) == label, "\(rate)")
        }
        #expect(MonitorCapturePresentation.title(.frameRate) == "FPS")
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
    @Test func reportedAndPendingReadoutsKeepTheirOwnValuesAndTheSameEditor() async throws {
        let clock = ManualClock()
        let camera = FakeCameraSession.lunaLike()
        await camera.cameraReportsStatus()
        let control = MonitorControlModel(sleep: { await clock.sleep($0) })
        control.bind(camera)
        #expect(await eventually { control.captureField(.iso)?.isEditable == true })
        let field = try #require(control.captureField(.iso))
        let originalReport = control.snapshot?.value(of: .iso)
        let choice = try #require(field.choices.first { $0.value == .iso(.manual(800)) })
        #expect(control.commit(choice, from: field))
        #expect(control.captureField(.iso)?.label == "800")
        #expect(control.captureField(.iso, selection: .pending)?.label == "800")
        #expect(control.captureField(.iso, selection: .reported)?.label == "200")
        #expect(control.captureValue(.iso, selection: .reported) == .iso(.manual(200)))
        #expect(control.captureField(.iso, selection: .reported)?.editor == field.editor)
        #expect(control.snapshot?.value(of: .iso) == originalReport)
        #expect(await camera.wire.isEmpty)
    }

    @available(macOS 14, *)
    @Test func readingMissingCommonObservationsNeverSelectsADefault() async throws {
        let camera = FakeCameraSession(behavior: FakeCameraSession.lunaLike().behavior,
            device: FakeDevice(rawMode: 0x01, settings: [], recording: nil))
        await camera.cameraReportsStatus()
        let control = MonitorControlModel()
        #expect(control.captureValue(.iso, selection: .reported) == nil)
        #expect(control.captureField(.iso) == nil)
        control.bind(camera)
        #expect(await eventually { control.snapshot?.mode.isKnown == true })
        for key in [SettingKey.iso, .shutter, .whiteBalance, .focusMode, .aperture, .exposureCompensation] {
            #expect(control.captureValue(key, selection: .reported) == nil)
            #expect(control.captureValue(key, selection: .pending) == nil)
        }
        #expect(await camera.wire.isEmpty)
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
