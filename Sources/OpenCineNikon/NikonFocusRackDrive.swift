import Foundation

/// Readiness polling selected once when a focus-rack controller captures its session access.
public enum NikonFocusRackCadence: Sendable {
    /// Existing cadence for callers that have not opted into faster rack qualification.
    case standard
    /// Finer early Busy polling; requires optical qualification on the selected lens and link.
    case fastExperimental

    fileprivate var earlyWaitCount: Int { self == .standard ? 6 : 24 }
    fileprivate var earlyWaitSeconds: Double { self == .standard ? 0.02 : 0.005 }
    fileprivate var pollLimit: Int { earlyWaitCount + 11 }
}

/// A single completed focus-rack chunk, or the reason its displacement cannot be trusted.
/// Command completion never establishes an absolute optical focus position.
public enum NikonFocusRackDriveOutcome: Codable, Equatable, Sendable {
    /// Readiness confirmed that the requested chunk completed.
    case complete
    /// Travel ended before the requested displacement could be established.
    case endOfTravel
    /// The lens could not execute this increment; do not count it as delivered movement.
    case stepTooSmall
    /// Cancellation and readiness were acknowledged; actual displacement is unknown.
    case cancelledReady
    /// A requested stop could not be confirmed on the camera.
    case cancelledUnconfirmed
    /// Transaction/completion uncertainty prevents position accounting.
    case uncertain
    /// Stop or source retirement prevented activation.
    case cancelledBeforeActivation
    /// The activation received an explicit non-OK response, preserving its raw code.
    case activationRejected(UInt16)

    /// Stable scalar representation shared with the optional Android session API.
    public var wireValue: Int32 {
        switch self {
        case .complete: 0
        case .endOfTravel: 1
        case .stepTooSmall: 2
        case .cancelledReady: 3
        case .cancelledUnconfirmed: 4
        case .uncertain: 5
        case .cancelledBeforeActivation: 6
        case .activationRejected(let code): 0x10000 | Int32(code)
        }
    }
}

/// One run's stop receipt. Requesting stop takes no camera or transaction lock.
/// Create a fresh receipt for every run; a stopped receipt cannot be rearmed.
package final class NikonFocusRackCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    /// Creates an unstopped run receipt.
    package init() {}

    /// Requests that the active drive stop at its next safe transaction boundary.
    package func requestStop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    /// Whether this receipt has been stopped.
    package var isStopRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

/// Run identity is independent of the command lock, so stop can reach a blocked drive.
package final class NikonFocusRackRunRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var latestRunID: Int64 = 0
    private var cancellation: NikonFocusRackCancellation?

    package init() {}

    package func prepare(runID: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard runID > latestRunID else { return false }
        cancellation?.requestStop()
        latestRunID = runID
        cancellation = NikonFocusRackCancellation()
        return true
    }

    package func requestStop(runID: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard runID > 0 else { return }
        if runID > latestRunID {
            cancellation?.requestStop()
            latestRunID = runID
            cancellation = NikonFocusRackCancellation()
        }
        guard runID == latestRunID else { return }
        cancellation?.requestStop()
    }

    package func requestStopCurrent() {
        lock.lock()
        defer { lock.unlock() }
        cancellation?.requestStop()
    }

    package func receipt(runID: Int64) -> NikonFocusRackCancellation? {
        lock.lock()
        defer { lock.unlock() }
        return runID == latestRunID ? cancellation : nil
    }
}

/// Shared wire sequencing for synchronous Android and asynchronous Apple transports.
package struct NikonFocusRackDriveMachine {
    package enum Action: Equatable {
        case activate, poll, cancel
        case wait(seconds: Double)
        case finished(NikonFocusRackDriveOutcome)
    }

    // Six short waits replace the first old 120ms wait. Later waits retain the dial's
    // cadence, preserving its 1.32s total sleep budget per readiness phase.
    package static let readinessPollLimit = MFDriveChannelBudget.readinessPollLimit + 5

    private enum Phase { case activation, driving, cancellation, confirming, finished }
    private var phase = Phase.activation
    private var polls = 0
    private var waits = false
    private var stopRequested = false
    private var outcome = NikonFocusRackDriveOutcome.uncertain
    private let cadence: NikonFocusRackCadence

    package init(cadence: NikonFocusRackCadence = .standard) {
        self.cadence = cadence
    }

    package mutating func next(stopRequested requested: Bool) -> Action {
        stopRequested = stopRequested || requested
        if stopRequested, phase == .activation {
            finish(.cancelledBeforeActivation)
        } else if stopRequested, phase == .driving {
            phase = .cancellation
            waits = false
        }
        if waits {
            waits = false
            return .wait(
                seconds: polls <= cadence.earlyWaitCount
                    ? cadence.earlyWaitSeconds : MFDriveChannelBudget.readinessPollIntervalSeconds)
        }
        switch phase {
        case .activation: return .activate
        case .driving, .confirming: return .poll
        case .cancellation: return .cancel
        case .finished: return .finished(outcome)
        }
    }

    package mutating func received(_ code: PTPResponseCode, rawResponseCode: UInt16? = nil) {
        switch phase {
        case .activation:
            if code == .ok {
                phase = .driving
            } else {
                finish(.activationRejected(rawResponseCode ?? code.rawValue))
            }
        case .driving:
            switch code {
            case .ok: finish(.complete)
            case .mfDriveStepEnd: finish(.endOfTravel)
            case .mfDriveStepInsufficiency: finish(.stepTooSmall)
            case .deviceBusy:
                polls += 1
                if polls >= cadence.pollLimit {
                    phase = .cancellation
                } else {
                    waits = true
                }
            default: phase = .cancellation
            }
        case .cancellation:
            if code == .ok {
                phase = .confirming
                polls = 0
            } else {
                finish(stopRequested ? .cancelledUnconfirmed : .uncertain)
            }
        case .confirming:
            if code == .ok {
                finish(stopRequested ? .cancelledReady : .uncertain)
            } else if code == .deviceBusy, polls + 1 < cadence.pollLimit {
                polls += 1
                waits = true
            } else {
                finish(stopRequested ? .cancelledUnconfirmed : .uncertain)
            }
        case .finished: break
        }
    }

    package mutating func transportFailed() {
        finish(stopRequested && phase != .activation ? .cancelledUnconfirmed : .uncertain)
    }

    private mutating func finish(_ result: NikonFocusRackDriveOutcome) {
        outcome = result
        phase = .finished
        waits = false
    }
}
