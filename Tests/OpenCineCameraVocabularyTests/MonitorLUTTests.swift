import Foundation
import Testing

@testable import OpenCineCameraVocabulary

@Suite struct MonitorLUTTests {
    private static let looks = CameraLUTProfile(automatic: [
        .dLog: .dji(.pocketDLog), .dLog2: .dji(.pocketDLog2), .iLog: .iLogRec709])

    @Test func unknownProfileDoesNotInferACameraLook() {
        #expect(LUTResolver.resolve(selection: .officialAuto, colorMode: .dLog2,
            hasCustomDLog: false, hasCustomDLog2: false) == .off)
        #expect(LUTResolver.resolve(selection: .djiDLogM, colorMode: .dLogM,
            hasCustomDLog: false, hasCustomDLog2: false) == .off)
    }

    /// Saved selections from before the neutral name still load as the official Auto row.
    @Test func officialAutoKeepsItsStoredRawValue() {
        #expect(LUTSelection.officialAuto.rawValue == "djiAuto")
        #expect(LUTSelection(rawValue: "djiAuto") == .officialAuto)
    }

    @Test func creativeLooksResolveToGeneratedLooks() {
        #expect(
            LUTResolver.resolve(
                selection: .creativeMono, colorMode: .dLog2, profile: Self.looks, hasCustomDLog: false,
                hasCustomDLog2: false)
                == .creative(.mono))
        #expect(LUTSelection.auto.migratedToDJICatalog == .officialAuto)
        #expect(LUTSelection.officialDLog2.migratedToDJICatalog == .djiDLog2)
    }

    /// I-Log has its own official cube; its stored raw value predates the capability name.
    @Test func autoAppliesTheILogCubeForILog() {
        for selection in [LUTSelection.auto, .officialAuto, .iLogRec709] {
            #expect(
                LUTResolver.resolve(
                    selection: selection, colorMode: .iLog, profile: Self.looks, hasCustomDLog: false,
                    hasCustomDLog2: false) == .iLogRec709)
        }
        #expect(
            LUTResolver.resolve(
                selection: .officialAuto, colorMode: .normal, profile: Self.looks, hasCustomDLog: false,
                hasCustomDLog2: false) == .off)
        #expect(LUTSelection.iLogRec709.title == "I-Log → Rec.709")
        #expect(LUTSelection.iLogRec709.isOfficial)
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
                selection: .officialAuto,
                colorMode: PlaybackLUTColor.resolve(live: .normal, last: .dLog2),
                profile: Self.looks, hasCustomDLog: false, hasCustomDLog2: false)
                == .dji(.pocketDLog2))
    }

    @Test func builtInAutoIgnoresCustomSlots() {
        #expect(
            LUTResolver.resolve(
                selection: .auto, colorMode: .dLog, profile: Self.looks, hasCustomDLog: true, hasCustomDLog2: true)
                == .dji(.pocketDLog))
        #expect(
            LUTResolver.resolve(
                selection: .auto, colorMode: .dLog2, profile: Self.looks, hasCustomDLog: true, hasCustomDLog2: true,
                hasCustomRec709: true)
                == .dji(.pocketDLog2))
        #expect(
            LUTResolver.resolve(
                selection: .auto, colorMode: .normal, profile: Self.looks, hasCustomDLog: false,
                hasCustomDLog2: false, hasCustomRec709: true)
                == .off)
        #expect(
            LUTResolver.resolve(
                selection: .auto, colorMode: .normal, profile: Self.looks, hasCustomDLog: false, hasCustomDLog2: false)
                == .off)
        #expect(
            LUTResolver.resolve(
                selection: .auto, colorMode: .hdr, profile: Self.looks, hasCustomDLog: true, hasCustomDLog2: true)
                == .off)
        #expect(
            LUTResolver.resolve(
                selection: .auto, colorMode: nil, profile: Self.looks, hasCustomDLog: false, hasCustomDLog2: false,
                hasCustomRec709: true)
                == .off)
    }

    @Test func manualSelectionIgnoresColorMode() {
        #expect(
            LUTResolver.resolve(
                selection: .officialDLog, colorMode: .dLog2, profile: Self.looks, hasCustomDLog: true,
                hasCustomDLog2: true)
                == .dji(.pocketDLog))
        #expect(
            LUTResolver.resolve(
                selection: .officialDLog2, colorMode: .dLog, profile: Self.looks, hasCustomDLog: false,
                hasCustomDLog2: false)
                == .dji(.pocketDLog2))
        #expect(
            LUTResolver.resolve(
                selection: .customDLog, colorMode: .dLog2, profile: Self.looks, hasCustomDLog: true,
                hasCustomDLog2: false)
                == .custom(.dLog))
        #expect(
            LUTResolver.resolve(
                selection: .customDLog2, colorMode: .dLog, profile: Self.looks, hasCustomDLog: false,
                hasCustomDLog2: false)
                == .off)
        #expect(
            LUTResolver.resolve(
                selection: .customRec709, colorMode: .dLog2, profile: Self.looks, hasCustomDLog: true,
                hasCustomDLog2: true,
                hasCustomRec709: true)
                == .custom(.rec709))
        #expect(
            LUTResolver.resolve(
                selection: .customRec709, colorMode: .normal, profile: Self.looks, hasCustomDLog: false,
                hasCustomDLog2: false)
                == .off)
    }

    @Test func autoFollowsTeleDLog2Fallback() {
        let current = ColorMode.dLog2
        let tele = CamFov.colorMode(forZoom: 3, current: current)
        #expect(tele == .dLog)
        #expect(
            LUTResolver.resolve(
                selection: .auto, colorMode: tele, profile: Self.looks, hasCustomDLog: false, hasCustomDLog2: true)
                == .dji(.pocketDLog))
        #expect(
            LUTResolver.resolve(
                selection: .officialAuto, colorMode: tele, profile: Self.looks, hasCustomDLog: true,
                hasCustomDLog2: true)
                == .dji(.pocketDLog))
        #expect(CamFov.colorMode(forZoom: 1, current: current) == nil)
        #expect(
            LUTResolver.resolve(
                selection: .auto, colorMode: .dLog2, profile: Self.looks, hasCustomDLog: false, hasCustomDLog2: true)
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
