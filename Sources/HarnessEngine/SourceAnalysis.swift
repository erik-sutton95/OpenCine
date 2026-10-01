import OpenCineCore
import OpenCineMedia

/// What one monitored picture's measurement tools analyze (plan 6.3, layers 1 and 2). One value
/// per picture source, held by that source's entry: never a process-wide preference, so two
/// cameras with different profiles or readings cannot affect each other.
///
/// Proposed shape for the `AnalysisConfiguration` plan 6.3 names; nothing in Core or Multicam
/// holds it yet (apps still keep their own per-feed copies).
public struct AnalysisConfiguration: Hashable, Sendable {
    /// Layer 1: the curve the received picture carries and where that came from (integration
    /// detection, or an operator override when the stream metadata cannot be trusted). Unknown
    /// gives no reading at all.
    public var signal: ObservedValue<MonitorTransfer>
    /// Layer 2: the operator reads false colour through the official Rec.709 look (709) instead of
    /// the camera signal (LOG).
    public var rec709Reading: Bool
    /// The integration's official look grey-axis curve for `signal`; `nil` when it has none, in
    /// which case the 709 reading stays on the signal.
    public var lookCurve: [Double]?
    public var scale: LiveFalseColorScale

    public init(
        signal: ObservedValue<MonitorTransfer>, rec709Reading: Bool, lookCurve: [Double]?,
        scale: LiveFalseColorScale = .ire
    ) {
        self.signal = signal
        self.rec709Reading = rec709Reading
        self.lookCurve = lookCurve
        self.scale = scale
    }

    /// WAVE IRE (0...100) of a neutral encoded code as this source's false colour reads it, or
    /// `nil` while the signal is unknown. `clipByte` is this source's live ceiling as its
    /// integration measured it; `nil` (unmeasured) keeps the encoded top.
    public func waveIRE(encoded: Double, clipByte: Int?) -> Double? {
        guard let transfer = signal.value else { return nil }
        let clip = LiveColorScience.falseColorClip(
            scale: scale, transfer: transfer, rec709: rec709Reading, lookCurve: lookCurve,
            clipEncoded: Double(clipByte ?? 255) / 255)
        let reading = LiveColorScience.falseColorReading(
            encoded: encoded, transfer: transfer, rec709: rec709Reading, lookCurve: lookCurve,
            scale: scale)
        return ScopeDisplayScale.monitorPercent(
            reading.encoded, transfer: reading.transfer,
            clipByte: Int((clip.ceiling * 255).rounded()))
    }
}
