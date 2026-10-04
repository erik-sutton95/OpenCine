import Foundation
import OpenCineDJI

/// One captured, coherent wire recipe. An unresolved model keeps the legacy
/// preparation/receiver fallback without manufacturing a model observation.
public enum DjiAppleLiveViewRecipe: Equatable, Sendable {
    case prepared, gated, direct, uncaptured, legacyUnresolved
    public static func captured(from model: CameraModel?) -> Self {
        guard let model else { return .legacyUnresolved }
        guard model.usesCapturedLiveEnable else { return .uncaptured }
        if model.usesNanoLiveViewGate { return .gated }
        return model.sendsLiveViewPrepare ? .prepared : .direct
    }
}

public enum DjiAppleLiveViewPurpose: Equatable, Sendable {
    case capturedRecipe, capturedMediaReturnRecipe
    case initial(pathProven: Bool, displayAttached: Bool)
    case recover(force: Bool)
    case firstPictureFormat, firstPictureResend, mediaReturn
}

/// Local transaction history, not camera observations or wire receipts.
public struct DjiAppleLiveViewHistory: Equatable, Sendable {
    public let initialAccepted: Bool
    public let locallyAcceptedEnables: Int
    public let lastAcceptedEnableWallTime: Date
    public let idrHoldEnableCount: Int
    public let gateInFlight: Bool
    internal init(initialAccepted: Bool = false, locallyAcceptedEnables: Int = 0,
        lastAcceptedEnableWallTime: Date = .distantPast, idrHoldEnableCount: Int = 0,
        gateInFlight: Bool = false) {
        self.initialAccepted = initialAccepted
        self.locallyAcceptedEnables = locallyAcceptedEnables
        self.lastAcceptedEnableWallTime = lastAcceptedEnableWallTime
        self.idrHoldEnableCount = idrHoldEnableCount
        self.gateInFlight = gateInFlight
    }
}

public enum DjiAppleLiveViewBlock: Equatable, Sendable {
    case unavailableOwnership, unavailableBinding, mediaBrowsing, playback
    case pathNotReady, presentationNotReady, cooldown, overlap, uncaptured, alreadyAccepted
}
public enum DjiAppleLiveViewOutcome: Equatable, Sendable {
    case locallyAccepted(DjiAppleLiveViewHistory)
    case blocked(DjiAppleLiveViewBlock)
    case superseded
}

/// Opaque authority for a real connection source and, for native effects, its
/// current operation. Construction is restricted to the actual owner.
@MainActor public final class DjiAppleLiveViewScope {
    internal enum Kind { case source, gate(UUID), repair(UInt64), completion(UInt64) }
    internal weak var owner: DjiApplePictureRecovery?
    internal let run: DjiAppleConnectionRun.Attempt
    internal let source: UUID
    internal let kind: Kind
    internal let binding: UUID?
    internal init(owner: DjiApplePictureRecovery, run: DjiAppleConnectionRun.Attempt,
        source: UUID, kind: Kind = .source, binding: UUID? = nil) {
        self.owner = owner; self.run = run; self.source = source; self.kind = kind; self.binding = binding
    }
    public var isCurrent: Bool { owner?.isLiveViewScopeCurrent(self) == true }
}

@MainActor public protocol DjiAppleLiveViewEndpoint: DjiAppleConnectionEndpoint {
    func startLiveView(receiver: UInt8)
}

/// Native facts sampled by the host from the actual source/presentation owner.
public struct DjiAppleNativeOutputObservation {
    public var pathReady: Bool
    public var playbackBlocked: Bool
    public var presentationReady: Bool
    public var awaitingIDR: Bool
    public var nativeOutputExpected: Bool
    public var nativeOutputAge: TimeInterval?
    public var lastIrapWallTime: TimeInterval?
    public var picture: DjiAppleRecoveryPicture
    public init(pathReady: Bool, playbackBlocked: Bool, presentationReady: Bool,
        awaitingIDR: Bool, nativeOutputExpected: Bool, nativeOutputAge: TimeInterval? = nil,
        lastIrapWallTime: TimeInterval? = nil, picture: DjiAppleRecoveryPicture = .init()) {
        self.pathReady = pathReady; self.playbackBlocked = playbackBlocked
        self.presentationReady = presentationReady; self.awaitingIDR = awaitingIDR
        self.nativeOutputExpected = nativeOutputExpected; self.nativeOutputAge = nativeOutputAge
        self.lastIrapWallTime = lastIrapWallTime; self.picture = picture
    }
}
public enum DjiAppleLiveViewNativeEffect {
    case prepareRecover, prepareMediaReturn, exitPlayback, holdPicture(always: Bool)
    case requestFinished(purpose: DjiAppleLiveViewPurpose, reason: String, outcome: DjiAppleLiveViewOutcome)
}
@MainActor public struct DjiAppleLiveViewNative {
    public var observeOutput: (TimeInterval, TimeInterval) -> DjiAppleNativeOutputObservation?
    public var perform: (DjiAppleLiveViewNativeEffect, DjiAppleLiveViewScope) -> Void
    public var rebuildOutput: (Bool, DjiAppleLiveViewScope) -> Bool
    public init(observeOutput: @escaping (TimeInterval, TimeInterval) -> DjiAppleNativeOutputObservation?,
        perform: @escaping (DjiAppleLiveViewNativeEffect, DjiAppleLiveViewScope) -> Void,
        rebuildOutput: @escaping (Bool, DjiAppleLiveViewScope) -> Bool) {
        self.observeOutput = observeOutput; self.perform = perform; self.rebuildOutput = rebuildOutput
    }
}
public enum DjiAppleNativeOutputResult: Equatable {
    case unspent, blockedReadiness, restored, presentationOnly
    case endpointRepair(DjiApplePictureRecovery.Result), fullRejoinRequired, superseded
}

#if os(iOS)
extension DjiAppleDatalink: DjiAppleLiveViewEndpoint {}
#endif
