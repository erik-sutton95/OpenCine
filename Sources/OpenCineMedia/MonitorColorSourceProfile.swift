import Foundation

/// An observed preview signature supplied by its integration. Order resolves overlapping ranges.
public struct MonitorTransferInferenceRule: Equatable, Sendable {
    public let fallback: MonitorTransfer
    public let transfer: MonitorTransfer
    public let minByte: ClosedRange<UInt8>
    public let maxByte: ClosedRange<UInt8>
    public init(fallback: MonitorTransfer, transfer: MonitorTransfer,
        minByte: ClosedRange<UInt8>, maxByte: ClosedRange<UInt8>) {
        self.fallback = fallback; self.transfer = transfer
        self.minByte = minByte; self.maxByte = maxByte
    }
}

/// Source-qualified clipping calibration and official Rec.709 gray-axis samples.
/// An absent calibration or look remains absent; published transfer math is independent of it.
public struct MonitorColorSourceProfile: Equatable, Sendable {
    public let clip: ScopeClipProfile
    public let rec709LookCurves: [MonitorTransfer: [Double]]
    public let transferInference: [MonitorTransferInferenceRule]

    public init(clip: ScopeClipProfile = .init(),
        rec709LookCurves: [MonitorTransfer: [Double]] = [:],
        transferInference: [MonitorTransferInferenceRule] = []) {
        precondition(rec709LookCurves.values.allSatisfy { $0.count >= 2 })
        self.clip = clip
        self.rec709LookCurves = rec709LookCurves
        self.transferInference = transferInference
    }

    public func inferredTransfer(minByte: UInt8, maxByte: UInt8,
        fallback: MonitorTransfer) -> MonitorTransfer {
        transferInference.first { $0.fallback == fallback
            && $0.minByte.contains(minByte) && $0.maxByte.contains(maxByte) }?.transfer ?? fallback
    }
}
