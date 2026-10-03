import Testing
@testable import OpenCineMedia

@Suite struct ScopeExposureCeilingTests {
    @Test func unknownSourceDoesNotInventISOOrCalibration() {
        let source = ScopeExposureCeiling()
        #expect(source.resolvedISO() == nil)
        #expect(source.clipByte(transfer: .dlog2) == 255)
        #expect(source.observeTapMax(247, transfer: .dlog2).maxRose == false)
    }
    @Test func storedBundleKeepsSamplingTimeCeiling() {
        let source = ScopeExposureCeiling(profile: ScopeClipProfile(calibrations: [
            .dlog2: ScopeClipCalibration(referenceISO: 1600, referenceByte: 247, refinementMaximumByte: 248),
        ], defaultISO: 1600))
        #expect(source.clipByte(transfer: .dlog2, iso: 0) == 247)
        #expect(source.clipByte(transfer: .dlog2, iso: -1) == 247)
        let bytes = [UInt8](repeating: 120, count: 4 * 4 * 4)
        let held = ScopeSampler.sample(bytes: bytes, width: 4, height: 4, bytesPerRow: 16,
            transfer: .dlog2, clipByte: source.clipByte(transfer: .dlog2),
            includePoints: false, look: nil, previous: .empty)
        source.setISO(800)
        #expect(source.clipByte(transfer: .dlog2) == 231)
        #expect(held.clipByte == 247)
        source.reset()
        #expect(source.clipByte(transfer: .dlog2) == 247)
        #expect(held.clipByte == 247)
    }
}
