import Foundation
import Testing

@testable import OpenCineCameraVocabulary

@Suite struct MonitorLUTTests {
    @Test func creativeLooksResolveToGeneratedLooks() {
        #expect(
            LUTResolver.resolve(
                selection: .creativeMono, colorMode: .dLog2, hasCustomDLog: false,
                hasCustomDLog2: false)
                == .creative(.mono))
        #expect(LUTSelection.auto.migratedToDJICatalog == .djiAuto)
        #expect(LUTSelection.officialDLog2.migratedToDJICatalog == .djiDLog2)
    }

    /// I-Log has its own official cube; its stored raw value predates the capability name.
    @Test func autoAppliesTheILogCubeForILog() {
        for selection in [LUTSelection.auto, .djiAuto, .iLogRec709] {
            #expect(
                LUTResolver.resolve(
                    selection: selection, colorMode: .iLog, hasCustomDLog: false,
                    hasCustomDLog2: false) == .iLogRec709)
        }
        #expect(
            LUTResolver.resolve(
                selection: .djiAuto, colorMode: .normal, hasCustomDLog: false,
                hasCustomDLog2: false) == .off)
        #expect(LUTSelection.iLogRec709.title == "I-Log → Rec.709")
        #expect(LUTSelection.iLogRec709.isDJI)
        #expect(LUTSelection(rawValue: "lunaILog") == .iLogRec709)
        #expect(
            LUTResolver.autoCaption(source: .iLogRec709) == "Applying official I-Log → Rec.709")
        #expect(!LUTSelection.djiCases.contains(.iLogRec709), "Pocket's catalog is unchanged")
    }

    @Test func playbackAutoKeepsLastLogWhenTheFileAndLiveSayRec709() {
        #expect(PlaybackLUTColor.resolve(live: .normal, last: .dLog2) == .dLog2)
        #expect(PlaybackLUTColor.resolve(live: .hdr, last: .dLog) == .dLog)
        #expect(PlaybackLUTColor.resolve(live: nil, last: .dLog2) == .dLog2)
        #expect(PlaybackLUTColor.resolve(live: .dLog2, last: .dLog2) == .dLog2)
        #expect(PlaybackLUTColor.resolve(live: .dLog2, last: .dLog) == .dLog2)
        #expect(PlaybackLUTColor.resolve(live: .normal, last: .normal) == .normal)
        #expect(PlaybackLUTColor.resolve(live: nil, last: nil) == nil)
        #expect(
            LUTResolver.resolve(
                selection: .djiAuto,
                colorMode: PlaybackLUTColor.resolve(live: .normal, last: .dLog2),
                hasCustomDLog: false, hasCustomDLog2: false)
                == .dji(.pocketDLog2))
    }

    @Test func builtInAutoIgnoresCustomSlots() {
        #expect(
            LUTResolver.resolve(
                selection: .auto, colorMode: .dLog, hasCustomDLog: true, hasCustomDLog2: true)
                == .dji(.pocketDLog))
        #expect(
            LUTResolver.resolve(
                selection: .auto, colorMode: .dLog2, hasCustomDLog: true, hasCustomDLog2: true,
                hasCustomRec709: true)
                == .dji(.pocketDLog2))
        #expect(
            LUTResolver.resolve(
                selection: .auto, colorMode: .normal, family: .pocket, hasCustomDLog: false,
                hasCustomDLog2: false, hasCustomRec709: true)
                == .off)
        #expect(
            LUTResolver.resolve(
                selection: .auto, colorMode: .normal, hasCustomDLog: false, hasCustomDLog2: false)
                == .off)
        #expect(
            LUTResolver.resolve(
                selection: .auto, colorMode: .hdr, hasCustomDLog: true, hasCustomDLog2: true)
                == .off)
        #expect(
            LUTResolver.resolve(
                selection: .auto, colorMode: nil, hasCustomDLog: false, hasCustomDLog2: false,
                hasCustomRec709: true)
                == .off)
    }

    @Test func djiAutoFollowsColorAndBody() {
        #expect(
            LUTResolver.resolve(
                selection: .djiAuto, colorMode: .dLog2, family: .pocket, hasCustomDLog: false,
                hasCustomDLog2: false)
                == .dji(.pocketDLog2))
        #expect(
            LUTResolver.resolve(
                selection: .djiAuto, colorMode: .dLog, family: .pocket, hasCustomDLog: false,
                hasCustomDLog2: false)
                == .dji(.pocketDLog))
        #expect(
            LUTResolver.resolve(
                selection: .djiAuto, colorMode: .dLogM, family: .nano,
                cameraName: "Osmo Nano", hasCustomDLog: false, hasCustomDLog2: false)
                == .dji(.nanoDLogM))
        #expect(
            LUTResolver.resolve(
                selection: .djiAuto, colorMode: .dLogM, family: .pocket,
                cameraName: "Osmo Pocket 3", hasCustomDLog: false, hasCustomDLog2: false)
                == .dji(.nanoDLogM))
        #expect(
            LUTResolver.resolve(
                selection: .djiAuto, colorMode: .dLogM, family: .other,
                cameraName: "Osmo Action 6", hasCustomDLog: false, hasCustomDLog2: false)
                == .dji(.action6DLogM))
        #expect(
            LUTResolver.resolve(
                selection: .djiDLogM, colorMode: .dLogM, family: .other,
                cameraName: "Osmo Action 6", hasCustomDLog: false, hasCustomDLog2: false)
                == .dji(.action6DLogM))
        #expect(
            LUTResolver.resolve(
                selection: .djiAuto, colorMode: .normal, family: .pocket, hasCustomDLog: false,
                hasCustomDLog2: false)
                == .off)
        #expect(
            LUTResolver.resolve(
                selection: .auto, colorMode: .dLog2, family: .nano, hasCustomDLog: false,
                hasCustomDLog2: false)
                == .dji(.nanoDLogM))
        #expect(
            LUTResolver.statusLabel(
                enabled: true, selection: .djiAuto, source: .dji(.pocketDLog2))
                == "Auto · D-Log2 → Rec.709")
    }

    @Test func manualSelectionIgnoresColorMode() {
        #expect(
            LUTResolver.resolve(
                selection: .officialDLog, colorMode: .dLog2, hasCustomDLog: true,
                hasCustomDLog2: true)
                == .dji(.pocketDLog))
        #expect(
            LUTResolver.resolve(
                selection: .officialDLog2, colorMode: .dLog, hasCustomDLog: false,
                hasCustomDLog2: false)
                == .dji(.pocketDLog2))
        #expect(
            LUTResolver.resolve(
                selection: .customDLog, colorMode: .dLog2, hasCustomDLog: true,
                hasCustomDLog2: false)
                == .custom(.dLog))
        #expect(
            LUTResolver.resolve(
                selection: .customDLog2, colorMode: .dLog, hasCustomDLog: false,
                hasCustomDLog2: false)
                == .off)
        #expect(
            LUTResolver.resolve(
                selection: .customRec709, colorMode: .dLog2, hasCustomDLog: true,
                hasCustomDLog2: true,
                hasCustomRec709: true)
                == .custom(.rec709))
        #expect(
            LUTResolver.resolve(
                selection: .customRec709, colorMode: .normal, hasCustomDLog: false,
                hasCustomDLog2: false)
                == .off)
    }

    @Test func autoFollowsTeleDLog2Fallback() {
        let current = ColorMode.dLog2
        let tele = CamFov.colorMode(forZoom: 3, current: current)
        #expect(tele == .dLog)
        #expect(
            LUTResolver.resolve(
                selection: .auto, colorMode: tele, hasCustomDLog: false, hasCustomDLog2: true)
                == .dji(.pocketDLog))
        #expect(
            LUTResolver.resolve(
                selection: .djiAuto, colorMode: tele, family: .pocket, hasCustomDLog: true,
                hasCustomDLog2: true)
                == .dji(.pocketDLog))
        #expect(CamFov.colorMode(forZoom: 1, current: current) == nil)
        #expect(
            LUTResolver.resolve(
                selection: .auto, colorMode: .dLog2, hasCustomDLog: false, hasCustomDLog2: true)
                == .dji(.pocketDLog2))
    }

    @Test func statusLabelDistinguishesAutoFromManual() {
        #expect(
            LUTResolver.statusLabel(
                enabled: true, selection: .auto, source: .official(.dLog2ToRec709))
                == "Auto · D-Log2 → Rec.709")
        #expect(
            LUTResolver.statusLabel(
                enabled: true, selection: .auto, source: .off)
                == "Auto · Off")
        #expect(
            LUTResolver.statusLabel(
                enabled: false, selection: .auto, source: .off)
                == "Off · Auto")
        #expect(
            LUTResolver.statusLabel(
                enabled: true, selection: .djiDLog, source: .dji(.pocketDLog))
                == "D-Log → Rec.709")
        #expect(
            LUTResolver.autoCaption(source: .off)
                == "No matching look for this color / camera")
        #expect(
            LUTResolver.autoCaption(source: .custom(.rec709))
                == "Applying Custom")
    }
}
