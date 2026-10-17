import Testing
import OpenCineCameraVocabulary

@testable import OpenCineCameraControls

@Suite struct LadderSheetTests {
    @Test func recordingAndCameraControlFreezeTheWholeSheet() {
        for lock in [CaptureLock.recording, CaptureLock.cameraControl] {
            let gates = ladderGates(sheetLock: lock, tabLock: nil, enabled: true)
            #expect(!gates.tabsEnabled)
            #expect(!gates.drumEnabled)
            #expect(gates.showBanner)
        }
    }

    @Test func autoAndExposureProgramFreezeOnlyTheDrum() {
        for lock in [CaptureLock.auto, CaptureLock.exposureProgram] {
            let gates = ladderGates(sheetLock: nil, tabLock: lock, enabled: true)
            #expect(gates.tabsEnabled)
            #expect(!gates.drumEnabled)
            #expect(gates.showBanner)
        }
    }

    @Test func aDisconnectedSheetStaysClosedEvenWithNoLock() {
        let gates = ladderGates(sheetLock: nil, tabLock: nil, enabled: false)
        #expect(!gates.tabsEnabled)
        #expect(!gates.drumEnabled)
        #expect(!gates.showBanner)
    }

    @available(macOS 14, *)
    @Test func activationWritesTheCircuitThenTheLandedValue() {
        let tab = sampleTab(activate: LadderWrite(key: "base", value: "Low"), apply: true)
        #expect(
            ladderActivationWrites(tab, landed: "800")
                == [LadderWrite(key: "base", value: "Low"), LadderWrite(key: "iso", value: "800")]
        )
    }

    @available(macOS 14, *)
    @Test func activationCanSkipTheLandedValue() {
        let tab = sampleTab(activate: LadderWrite(key: "mode", value: "Angle"), apply: false)
        #expect(
            ladderActivationWrites(tab, landed: "180") == [LadderWrite(key: "mode", value: "Angle")]
        )
    }

    @available(macOS 14, *)
    @Test func aBlankLandedValueIsNotWritten() {
        #expect(ladderActivationWrites(sampleTab(apply: true), landed: "").isEmpty)
    }

    @available(macOS 14, *)
    @Test func aGrownLadderReplacesTheCameraList() {
        let grown = LadderTab(
            label: "ISO", key: "iso",
            ladder: CaptureLadder(current: "800", values: ["400", "800"]),
            values: { landed in ["5560K", landed] }
        )
        #expect(ladderOptions(grown, landed: "5600K") == ["5560K", "5600K"])
        #expect(ladderOptions(sampleTab(), landed: "800") == ["400", "800"])
    }

    @Test func aStepCanRefuseToLandOnTheDrum() {
        let depth = LadderStep(
            label: "10-bit", value: "H.265 10-bit", description: "Record H.265 at 10-bit",
            selected: true, lands: false)
        let kelvin = LadderStep(
            label: "\u{2212}10", value: "5550K", description: "Decrease Kelvin by 10", lands: true)
        #expect(!depth.lands)
        #expect(LadderStep(label: "+10", value: nil, description: "Increase Kelvin by 10").value == nil)
        #expect(kelvin.lands)
        #expect(kelvin.value == "5550K")
    }

    @available(macOS 14, *)
    @Test func aFormatPickWritesOnlyALadderValueWhileTheDrumIsOpen() {
        #expect(
            ladderFormatWrite(sampleTab(), value: "400", enabled: true)
                == LadderWrite(key: "iso", value: "400"))
        #expect(ladderFormatWrite(sampleTab(), value: "1600", enabled: true) == nil)
        #expect(ladderFormatWrite(sampleTab(), value: "400", enabled: false) == nil)
    }

    @available(macOS 14, *)
    private func sampleTab(
        activate: LadderWrite<String>? = nil, apply: Bool = true
    ) -> LadderTab<String> {
        LadderTab(
            label: "ISO", key: "iso",
            ladder: CaptureLadder(current: "800", values: ["400", "800"]),
            activate: activate, applyOnActivate: apply)
    }
}
