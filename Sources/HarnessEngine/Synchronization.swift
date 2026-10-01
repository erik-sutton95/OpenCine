import OpenCineCore
import OpenCineMulticam

/// How well the host knows one camera's clock (plan 8.3, "clock relationship").
public enum ClockRelationship: Hashable, Sendable {
    case unknown
    /// The camera reported its clock and the host compared it, within this many seconds.
    case measured(uncertaintySeconds: Double)

    /// Only a valid camera-reported clock with a stated precision is a measurement. A time the
    /// host derived from a clock it set itself (`.clockDerived`), estimated, or was told by the
    /// operator is not: the camera never confirmed it.
    public init(_ cameraClockOffset: ObservedValue<Duration>) {
        guard cameraClockOffset.isKnown, cameraClockOffset.origin == .cameraReported,
            cameraClockOffset.validity == .valid
        else {
            self = .unknown
            return
        }
        switch cameraClockOffset.precision {
        case .approximate(let plusOrMinus)?: self = .measured(uncertaintySeconds: plusOrMinus)
        case .quantized(let step)?: self = .measured(uncertaintySeconds: step)
        case .exact?, nil: self = .unknown  // no stated bound: a transport delay is still unmeasured
        }
    }
}

/// Plan 8.3 levels of one group record, each reported on its own. There is deliberately no
/// "synchronized" flag: a group command is coordinated best-effort dispatch with per-camera
/// confirmation, and no integration offers a hardware trigger, genlock or jam sync.
///
/// Proposed for OpenCineMulticam, which does not model synchronization levels yet (MULTI-01 notes).
public struct GroupSyncReport: Hashable, Sendable {
    /// Cameras whose own report confirmed the requested state.
    public var confirmed: Set<CameraSessionID>
    /// Cameras commanded but not (yet) confirmed: pending, timed out, refused or unknown.
    public var unconfirmed: Set<CameraSessionID>
    public var clocks: [CameraSessionID: ClockRelationship]

    public init(_ result: RecordResult, cameraClocks: [CameraSessionID: ObservedValue<Duration>]) {
        confirmed = Set(result.outcomes.filter { $0.value == .confirmed }.keys)
        unconfirmed = Set(result.outcomes.keys).subtracting(confirmed)
        clocks = result.outcomes.keys.reduce(into: [:]) { clocks, session in
            clocks[session] = cameraClocks[session].map(ClockRelationship.init) ?? .unknown
        }
    }
}
