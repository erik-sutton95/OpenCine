import Foundation

/// Source-qualified preview saturation. Integrations supply measured values for their source.
public struct ScopeClipCalibration: Equatable, Sendable {
    public var referenceISO: Int
    public var referenceByte: UInt8
    public var refinementMaximumByte: UInt8
    public var noiseAllowance: Int
    public var refinementAtOrAboveReference: Bool

    public init(referenceISO: Int, referenceByte: UInt8, refinementMaximumByte: UInt8? = nil,
        noiseAllowance: Int = 2, refinementAtOrAboveReference: Bool = false) {
        precondition(referenceISO > 0 && referenceByte > 0 && referenceByte < 255)
        let maximum = refinementMaximumByte ?? referenceByte
        precondition(maximum >= referenceByte && maximum < 255 && noiseAllowance >= 0)
        self.referenceISO = referenceISO; self.referenceByte = referenceByte
        self.refinementMaximumByte = maximum; self.noiseAllowance = noiseAllowance
        self.refinementAtOrAboveReference = refinementAtOrAboveReference
    }
}

public struct ScopeClipProfile: Equatable, Sendable {
    public var calibrations: [MonitorTransfer: ScopeClipCalibration]
    public var defaultISO: Int?
    /// ISO the ceiling assumes when the source reports that its ISO is not known (an Auto ISO
    /// camera that does not publish the applied value). `nil` keeps the last known report.
    /// A source whose clip falls below its reference ISO names its lowest ISO here, so an
    /// unreported Auto ISO can only warn early, never miss a clip.
    public var unreportedISO: Int?
    public init(calibrations: [MonitorTransfer: ScopeClipCalibration] = [:], defaultISO: Int? = nil,
        unreportedISO: Int? = nil) {
        precondition(unreportedISO.map { (50...102_400).contains($0) } ?? true)
        self.calibrations = calibrations; self.defaultISO = defaultISO
        self.unreportedISO = unreportedISO
    }
}

/// ISO and tap history of one source. Native engines and views share this source-owned state.
open class ScopeExposureCeiling: @unchecked Sendable {
    public static let clipShelfCodes = ScopeAnchors.clipShelfCodes
    private struct Key: Hashable { var transfer: MonitorTransfer; var iso: Int? }
    private struct State {
        var iso: Int?
        var refined: [MonitorTransfer: UInt8] = [:]
        var observed: [Key: UInt8] = [:]
        /// Clips the source states outright, per transfer (``declare(clipByte:for:)``).
        var declared: [MonitorTransfer: Int] = [:]
        var lastLoggedMax: UInt8 = 0
    }
    private let profile: ScopeClipProfile
    private var state: State
    private let lock = NSLock()

    public init(profile: ScopeClipProfile = .init()) {
        self.profile = profile; self.state = State(iso: profile.defaultISO)
    }
    private func withLock<T>(_ body: (inout State) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&state)
    }
    public func setISO(_ iso: Int) {
        guard (50...102_400).contains(iso) else { return }
        withLock { $0.iso = iso }
    }
    /// Applies a camera report. A positive ISO is set as ``setISO(_:)`` does. `nil`, zero or a
    /// negative value means the camera did not report its applied ISO: the ceiling moves to the
    /// profile's ``ScopeClipProfile/unreportedISO`` when it names one, else keeps the last report.
    public func syncISO(_ iso: Int?) {
        if let iso, iso > 0 { setISO(iso); return }
        guard let unreported = profile.unreportedISO else { return }
        withLock { $0.iso = unreported }
    }
    public func resolvedISO() -> Int? { withLock { $0.iso } }
    /// The profile's assumption for an unreported ISO; `nil` keeps the last report.
    public var unreportedISO: Int? { profile.unreportedISO }
    /// A clip the source states for `transfer` at its current settings (a camera's published
    /// overexposure warning code for its ISO), in place of measured calibration and tap
    /// history for that transfer. `nil` withdraws it. The source restates it when a setting
    /// that moves it changes; ``reset()`` clears it with the rest of the source's state.
    public func declare(clipByte: Int?, for transfer: MonitorTransfer) {
        withLock { $0.declared[transfer] = clipByte.map { min(255, max(1, $0)) } }
    }
    public func reset() { withLock { $0 = State(iso: profile.defaultISO) } }
    public func clipShelfByte(transfer: MonitorTransfer, iso: Int? = nil) -> Int {
        ScopeAnchors.clipShelfByte(clipByte: clipByte(transfer: transfer, iso: iso))
    }
    public func clipEncoded(transfer: MonitorTransfer, iso: Int? = nil) -> Double {
        Double(clipByte(transfer: transfer, iso: iso)) / 255
    }
    public func clipByte(transfer: MonitorTransfer, iso: Int? = nil) -> Int {
        withLock { s in
            if let declared = s.declared[transfer] { return declared }
            let ei = iso.flatMap { $0 > 0 ? $0 : nil } ?? s.iso
            return max(tableByte(transfer: transfer, iso: ei, state: s),
                Int(s.observed[Key(transfer: transfer, iso: ei)] ?? 0))
        }
    }
    public func anchors(transfer: MonitorTransfer, iso: Int? = nil) -> ScopeAnchors {
        ScopeAnchors.make(transfer: transfer, clipByte: clipByte(transfer: transfer, iso: iso))
    }
    @discardableResult public func observeTapMax(
        _ byte: UInt8, transfer: MonitorTransfer
    ) -> (clip: UInt8, maxRose: Bool) {
        guard let calibration = profile.calibrations[transfer], byte > 0 && byte < 255,
            withLock({ $0.declared[transfer] }) == nil
        else {
            return (UInt8(clipByte(transfer: transfer)), false)
        }
        return withLock { s in
            let ei = s.iso ?? calibration.referenceISO
            let atReference = calibration.refinementAtOrAboveReference
                ? ei >= calibration.referenceISO : ei == calibration.referenceISO
            if atReference && byte > (s.refined[transfer] ?? calibration.referenceByte)
                && byte <= calibration.refinementMaximumByte { s.refined[transfer] = byte }
            let table = tableByte(transfer: transfer, iso: s.iso, state: s)
            let key = Key(transfer: transfer, iso: s.iso)
            let previous = Int(s.observed[key] ?? 0)
            let raised = min(max(previous, Int(byte)), min(254, table + calibration.noiseAllowance))
            if raised > table { s.observed[key] = UInt8(raised) }
            let clip = max(table, Int(s.observed[key] ?? 0))
            let maxRose = byte > s.lastLoggedMax
            if maxRose { s.lastLoggedMax = byte }
            return (UInt8(clip), maxRose)
        }
    }
    private func tableByte(transfer: MonitorTransfer, iso: Int?, state: State) -> Int {
        guard let calibration = profile.calibrations[transfer] else { return 255 }
        let ei = iso ?? calibration.referenceISO
        let reference = state.refined[transfer] ?? calibration.referenceByte
        let refLinear = LiveColorScience.linearize(Double(reference) / 255, transfer: transfer)
        let linear = ei >= calibration.referenceISO
            ? refLinear : refLinear * Double(ei) / Double(calibration.referenceISO)
        return min(254, max(1, Int((LiveColorScience.encode(linear, transfer: transfer) * 255).rounded())))
    }
}
