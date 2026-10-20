import OpenCineMedia
import Testing
@testable import Insta360Protocol

/// Luna I-Log preview clip per ISO (twin of Kotlin `LunaScopeClipTest`). The values are
/// derived, not measured: see `LunaScopeClip` and the hardware procedure it names.
struct LunaScopeClipTests {
    @Test func iLogClipFallsBelowTheNativeISOAndHoldsAtAndAboveIt() {
        let ceiling = ScopeExposureCeiling(profile: LunaScopeClip.profile)
        let expected = [100: 205, 160: 220, 200: 227, 400: 248, 800: 248, 1600: 248, 3200: 248, 6400: 248]
        for (iso, byte) in expected {
            #expect(ceiling.clipByte(transfer: .ilog, iso: iso) == byte, "ISO \(iso)")
        }
        #expect(LunaScopeClip.nativeISO == 400)
        #expect(LunaScopeClip.lowestISO == 100)
    }

    @Test func aFrameAtTheISO100ClipIsFlaggedClipped() {
        let ceiling = ScopeExposureCeiling(profile: LunaScopeClip.profile)
        ceiling.syncISO(100)
        let clip = ceiling.clipByte(transfer: .ilog)
        #expect(clip == 205)
        var bins = [Int](repeating: 0, count: 256)
        bins[clip] = 1000
        let reading = ScopeTrafficLights.reading(red: bins, green: bins, blue: bins, luma: bins,
            transfer: .ilog, clipByte: clip)
        #expect(reading.anyClip)
        // The fixed 255 ceiling Luna used before never reached this frame.
        let fixed = ScopeTrafficLights.reading(red: bins, green: bins, blue: bins, luma: bins,
            transfer: .ilog, clipByte: ScopeExposureCeiling().clipByte(transfer: .ilog))
        #expect(!fixed.anyClip)
    }

    @Test func unreportedAutoISOAssumesTheLowestISOAndNeverKeepsAStaleManualOne() {
        let ceiling = ScopeExposureCeiling(profile: LunaScopeClip.profile)
        #expect(ceiling.resolvedISO() == 100)
        ceiling.syncISO(800)
        #expect(ceiling.clipByte(transfer: .ilog) == 248)
        // Luna reports ISO 0 in Auto (the applied value is not published).
        ceiling.syncISO(0)
        #expect(ceiling.resolvedISO() == 100)
        #expect(ceiling.clipByte(transfer: .ilog) == 205)
        ceiling.syncISO(200)
        ceiling.syncISO(nil)
        #expect(ceiling.clipByte(transfer: .ilog) == 205)
    }

    @Test func otherCurvesKeepTheirUncalibratedCeiling() {
        let ceiling = ScopeExposureCeiling(profile: LunaScopeClip.profile)
        #expect(ceiling.clipByte(transfer: .rec709, iso: 100) == 255)
        #expect(Set(LunaScopeClip.profile.calibrations.keys) == [.ilog])
    }
}
