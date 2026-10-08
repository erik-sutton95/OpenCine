import Testing
@testable import OpenCineDJI

@Suite struct DJICameraLUTProfileTests {
    @Test func djiAutoFollowsColorAndBody() {
        #expect(
            LUTResolver.resolve(
                selection: .officialAuto, colorMode: .dLog2, profile: DJICameraLUTProfile.make(family: .pocket, cameraName: nil), hasCustomDLog: false,
                hasCustomDLog2: false)
                == .dji(.pocketDLog2))
        #expect(
            LUTResolver.resolve(
                selection: .officialAuto, colorMode: .dLog, profile: DJICameraLUTProfile.make(family: .pocket, cameraName: nil), hasCustomDLog: false,
                hasCustomDLog2: false)
                == .dji(.pocketDLog))
        #expect(
            LUTResolver.resolve(
                selection: .officialAuto, colorMode: .dLogM, profile: DJICameraLUTProfile.make(family: .nano, cameraName: "Osmo Nano"), hasCustomDLog: false, hasCustomDLog2: false)
                == .dji(.nanoDLogM))
        #expect(
            LUTResolver.resolve(
                selection: .officialAuto, colorMode: .dLogM, profile: DJICameraLUTProfile.make(family: .pocket, cameraName: "Osmo Pocket 3"), hasCustomDLog: false, hasCustomDLog2: false)
                == .dji(.nanoDLogM))
        #expect(
            LUTResolver.resolve(
                selection: .officialAuto, colorMode: .dLogM, profile: DJICameraLUTProfile.make(family: .other, cameraName: "Osmo Action 6"), hasCustomDLog: false, hasCustomDLog2: false)
                == .dji(.action6DLogM))
        #expect(
            LUTResolver.resolve(
                selection: .djiDLogM, colorMode: .dLogM, profile: DJICameraLUTProfile.make(family: .other, cameraName: "Osmo Action 6"), hasCustomDLog: false, hasCustomDLog2: false)
                == .dji(.action6DLogM))
        #expect(
            LUTResolver.resolve(
                selection: .officialAuto, colorMode: .normal, profile: DJICameraLUTProfile.make(family: .pocket, cameraName: nil), hasCustomDLog: false,
                hasCustomDLog2: false)
                == .off)
        #expect(
            LUTResolver.resolve(
                selection: .auto, colorMode: .dLog2, profile: DJICameraLUTProfile.make(family: .nano, cameraName: nil), hasCustomDLog: false,
                hasCustomDLog2: false)
                == .dji(.nanoDLogM))
        #expect(
            LUTResolver.statusLabel(
                enabled: true, selection: .officialAuto, source: .dji(.pocketDLog2))
                == "Auto · D-Log2 → Rec.709")
    }

}
