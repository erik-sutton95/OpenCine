import OpenCineCameraVocabulary
import OpenCineCore
import Testing

@testable import OpenCineNikon

/// The Nikon capture popups as values: the tabs, locks, writes and steps the shared ladder sheet
/// draws, so the Z app only reads the session and routes writes.
@Suite struct NikonCapturePopupTests {
    private func state(
        _ kind: NikonCapturePopupKind, _ modes: [NikonLadderMode]
    ) -> NikonCapturePopupState {
        NikonCapturePopupState(kind: kind, title: "T", subtitle: "S", modes: modes)
    }

    private func mode(_ index: Int, _ title: String, _ options: [String] = ["A", "B"])
        -> NikonLadderMode
    {
        NikonLadderMode(index: index, title: title, options: options, current: options.first ?? "")
    }

    @Test func photoAutoISOLadderKeepsTheBodysOffLadderPick() {
        #expect(
            NikonCapturePopupState.including("3600", in: ["3200", "4000"]) == [
                "3200", "3600", "4000",
            ])
        #expect(
            NikonCapturePopupState.including("51200", in: ["100", "25600"]) == [
                "100", "25600", "51200",
            ])
        #expect(
            NikonCapturePopupState.including("50", in: ["100", "200"]) == ["50", "100", "200"])
        #expect(NikonCapturePopupState.including("800", in: ["400", "800"]) == ["400", "800"])
        #expect(NikonCapturePopupState.including(nil, in: ["800"]) == ["800"])
        #expect(NikonCapturePopupState.including("Auto", in: ["800"]) == ["800"])
    }

    @Test func autoISOLocksEachDrumAndLeavingAutoWritesTheCircuit() {
        var popup = state(.iso, [mode(0, "Auto On"), mode(1, "Auto Off")])
        popup.autoISO = true
        popup.isoCameraOwned = true
        popup.circuitIndex = 0
        let sheet = popup.presentation
        #expect(sheet.lock == nil)
        #expect(sheet.tabs.allSatisfy { $0.ladder.lock == .auto })
        #expect(sheet.lockBanner?.hasPrefix("Auto ISO is on") == true)
        #expect(sheet.tabs[0].activate == LadderWrite(key: .autoISO, value: "On"))
        #expect(sheet.tabs[0].applyOnActivate == false)
        #expect(sheet.tabs[1].activate == LadderWrite(key: .autoISO, value: "Off"))
        #expect(sheet.tabs[1].applyOnActivate)

        popup.isoRecordingLocked = true
        #expect(popup.presentation.lock == .recording)
        #expect(popup.presentation.tabs.allSatisfy { $0.ladder.lock == nil })
    }

    @Test func shutterCircuitTabsWriteOnlyTheCircuitAndTheCameraLockFreezesTheSheet() {
        var popup = state(.shutter, [mode(0, "Angle"), mode(1, "Speed")])
        popup.circuitIndex = 1
        // Pocket's order: Speed, Angle. The Speed tab keeps the body's mode index 1.
        #expect(popup.presentation.tabs.map(\.label) == ["Speed", "Angle"])
        #expect(popup.presentation.tabs.map(\.key) == [.value(1), .value(0)])
        #expect(popup.presentation.initialTab == 0)
        #expect(
            popup.presentation.tabs[0].activate == LadderWrite(key: .shutterMode, value: "Speed"))
        #expect(popup.presentation.tabs[0].applyOnActivate == false)
        popup.circuitIndex = 0
        #expect(popup.presentation.initialTab == 1)
        popup.shutterLockedOnCamera = true
        #expect(popup.presentation.lock == .cameraControl)
        #expect(
            popup.presentation.lockBanner == "Shutter locked on camera. Hold anywhere to unlock.")
    }

    @Test func photoISOAutoTabIsLockedAndCentresOnTheLivePick() {
        var popup = state(
            .stillISO, [mode(0, "Auto", ["3200", "4000"]), mode(1, "Manual", ["3200", "4000"])])
        popup.liveISO = 3600
        let sheet = popup.presentation
        #expect(sheet.tabs[0].ladder.lock == .auto)
        #expect(sheet.tabs[0].ladder.values == ["3200", "3600", "4000"])
        #expect(sheet.tabs[1].ladder.lock == nil)
        #expect(sheet.tabs[1].activate == LadderWrite(key: .stillAutoISO, value: "Off"))
    }

    @Test func whiteBalanceOffersKelvinStepsPresetsAndTheTintPad() {
        var popup = state(
            .whiteBalance,
            [mode(0, "Kelvin", []), mode(1, "Preset", ["Auto", "Daylight"]), mode(2, "Tint", [])])
        popup.whiteBalanceMode = "Daylight"
        popup.codec = "H.265"
        popup.tintCells = (2, -1)
        popup.tintAvailable = true
        popup.typed = .whiteBalance
        let sheet = popup.presentation
        // Pocket's order and labels: Mode (the body's presets), Kelvin, Tint; keys stay mode indices.
        #expect(sheet.tabs.map(\.label) == ["Mode", "Kelvin", "Tint"])
        #expect(sheet.tabs.map(\.key) == [.value(1), .value(0), .value(2)])
        #expect(sheet.initialTab == 0)
        #expect(sheet.tabs[1].ladder.values == WhiteBalanceKelvinPolicy.kelvinOptions)
        #expect(sheet.tabs[1].setting == nil)
        let steps = sheet.tabs[1].steps?("5600K")
        #expect(steps?.0.label == "\u{2212}10")
        #expect(steps?.1.lands == true)
        // Behavior audit ZIA-145: the drum tells VoiceOver what the buttons beside it do.
        #expect(sheet.tabs[1].stepsHint == NikonCapturePopupState.kelvinStepsHint)
        #expect(
            NikonCapturePopupState.kelvinStepsHint
                == "Use minus 10 and plus 10 beside the selected value to fine-adjust")
        #expect(sheet.tabs[0].stepsHint == nil)
        #expect(sheet.tabs[1].values?("5610K").contains("5610K") == true)
        #expect(
            sheet.tabs[0].ladder.values
                == PTPCameraPropertyDecoders.whiteBalanceOptions(
                    advertised: ["Auto", "Daylight"], codec: "H.265"))
        #expect(
            sheet.tabs[2].tint
                == CaptureTint(greenMagenta: -1, amberBlue: 2, range: WhiteBalanceTint.cellRange))
        #expect(sheet.tabs[2].activate == nil)
        popup.whiteBalanceMode = "Color temp"
        #expect(popup.presentation.initialTab == 1)

        popup.tintAvailable = false
        #expect(popup.presentation.tabs[2].ladder.lock == .auto)
    }

    @Test func advertisedValuesWinOverTheAppLadderAndPlainSettingsOpenOnTheBodysValue() {
        var popup = state(
            .settings,
            [
                NikonLadderMode(index: 0, title: "One", options: ["A", "B"], current: "A"),
                NikonLadderMode(
                    index: 1, title: "Two", options: ["C", "D"], current: "",
                    advertised: ["D", "E"]),
            ])
        popup.cameraValue = "E"
        let sheet = popup.presentation
        #expect(sheet.tabs[1].ladder.values == ["D", "E"])
        #expect(sheet.tabs[1].ladder.current == nil)
        #expect(sheet.initialTab == 1)
        popup.seededTab = 0
        #expect(popup.presentation.initialTab == 0)
    }

    @Test func independentTabsAndApertureNeverWriteOnTabChange() {
        let focus = state(.independentTabs, [mode(0, "Mode"), mode(1, "Area")]).presentation
        #expect(focus.tabs.allSatisfy { $0.activate == nil && !$0.applyOnActivate })
        var iris = state(.aperture, [mode(0, "Iris", ["f/2.8"])])
        iris.lensApertures = ["f/1.8", "f/2"]
        #expect(iris.presentation.tabs[0].ladder.values == ["f/1.8", "f/2"])
        #expect(iris.presentation.tabs[0].applyOnActivate)
    }

    @Test func aBaseValueIsMarkedOnItsTab() {
        let popup = state(
            .settings,
            [NikonLadderMode(index: 0, title: "One", options: ["A", "B"], base: "B", current: "A")])
        #expect(popup.presentation.tabs[0].ladder.marked == ["B"])
    }
}
