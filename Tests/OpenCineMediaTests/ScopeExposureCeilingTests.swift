import Testing
@testable import OpenCineMedia

@Suite struct ScopeExposureCeilingTests {
    @Test func anUnreportedISOKeepsTheLastReportUnlessTheProfileNamesAnAssumption() {
        let calibrations: [MonitorTransfer: ScopeClipCalibration] = [
            .dlog2: ScopeClipCalibration(referenceISO: 1600, referenceByte: 247, refinementMaximumByte: 248),
        ]
        let keeps = ScopeExposureCeiling(profile: ScopeClipProfile(calibrations: calibrations, defaultISO: 1600))
        keeps.syncISO(800)
        keeps.syncISO(0)
        keeps.syncISO(-1)
        keeps.syncISO(nil)
        #expect(keeps.resolvedISO() == 800)
        let assumes = ScopeExposureCeiling(profile: ScopeClipProfile(
            calibrations: calibrations, defaultISO: 1600, unreportedISO: 100))
        assumes.syncISO(800)
        #expect(assumes.clipByte(transfer: .dlog2) == 231)
        assumes.syncISO(0)
        #expect(assumes.resolvedISO() == 100)
        #expect(assumes.clipByte(transfer: .dlog2) < 231)
        assumes.syncISO(25)
        #expect(assumes.resolvedISO() == 100)
        assumes.syncISO(1600)
        #expect(assumes.clipByte(transfer: .dlog2) == 247)
    }
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
    @Test func aDeclaredClipReplacesCalibrationUntilWithdrawn() {
        let source = ScopeExposureCeiling(profile: ScopeClipProfile(calibrations: [
            .dlog2: ScopeClipCalibration(referenceISO: 1600, referenceByte: 247, refinementMaximumByte: 248),
        ], defaultISO: 1600))
        // A camera that publishes its warning code states it; no tap may ratchet past it.
        source.declare(clipByte: 180, for: .log3G10)
        #expect(source.clipByte(transfer: .log3G10) == 180)
        #expect(source.observeTapMax(200, transfer: .log3G10).clip == 180)
        source.declare(clipByte: 230, for: .dlog2)
        let held = source.observeTapMax(248, transfer: .dlog2)
        #expect(held.clip == 230 && !held.maxRose)
        #expect(source.clipByte(transfer: .dlog2, iso: 800) == 230)
        source.declare(clipByte: nil, for: .dlog2)
        #expect(source.clipByte(transfer: .dlog2) == 247)
        source.declare(clipByte: 900, for: .nlog)
        #expect(source.clipByte(transfer: .nlog) == 255)
        source.reset()
        #expect(source.clipByte(transfer: .log3G10) == 255)
    }
}
