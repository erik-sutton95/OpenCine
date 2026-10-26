import Foundation
import OpenCineGyro

/// A scripted `GyroCameraAdapter` for coordinator and view tests. Tests push camera observations
/// with `send(_:)` or `connect(...)` and read every stabilization write the session made. An
/// accepted write is echoed back as a `.stabilization` report, as a real camera would report it.
@MainActor public final class FakeGyroCameraAdapter: GyroCameraAdapter {
    /// The body `connect(...)` reports.
    public var identity: GyroCameraIdentity
    public let providesLevel: Bool
    public let stabilizationSettings: [GyroStabilizationSetting]
    /// Every `writeStabilization` call, in order, accepted or not.
    public var writes: [[String: String]] = []
    /// When false, every write is refused and nothing is echoed.
    public var acceptsWrites = true
    /// When true, each write waits until the test resolves it with `resolveHeldWrite`.
    public var holdsWrites = false
    /// The stabilization values the fake camera currently reports.
    public private(set) var stabilization: GyroStabilizationState?
    private weak var sink: (any GyroCameraSink)?
    private var held: [CheckedContinuation<Bool, Never>] = []

    /// Creates a fake body; the default has a level sensor and one in-body stabilization control.
    public init(
        identity: GyroCameraIdentity = .init(id: "fake-1", name: "Test camera"),
        providesLevel: Bool = true,
        settings: [GyroStabilizationSetting] = [.init(key: "ibis", title: "IBIS", offValue: "OFF")]
    ) {
        self.identity = identity
        self.providesLevel = providesLevel
        stabilizationSettings = settings
    }

    /// Whether a sink is attached.
    public var isAttached: Bool { sink != nil }

    /// Writes waiting for the test, oldest first.
    public var heldWriteCount: Int { held.count }

    /// Settles one held write, by default the oldest. A refused write is not echoed.
    public func resolveHeldWrite(at index: Int = 0, succeeded: Bool) {
        held.remove(at: index).resume(returning: succeeded)
    }

    public func attach(_ sink: any GyroCameraSink) { self.sink = sink }

    public func detach() { sink = nil }

    public func writeStabilization(_ values: [String: String]) async -> Bool {
        writes.append(values)
        if holdsWrites {
            let succeeded = await withCheckedContinuation { held.append($0) }
            guard succeeded else { return false }
        }
        guard acceptsWrites else { return false }
        var merged = stabilization?.values ?? [:]
        for (key, value) in values { merged[key] = value }
        send(.stabilization(.init(values: merged, lensHasVRSwitch: stabilization?.lensHasVRSwitch)))
        return true
    }

    /// Forwards one observation to the attached sink, tracking reported stabilization.
    public func send(_ event: GyroCameraEvent) {
        if case .stabilization(let state) = event { stabilization = state }
        sink?.receive(event)
    }

    /// Reports a connection the way an integration should: identity, stabilization, recording,
    /// then video mode, so the session sees the full camera state when it becomes eligible.
    public func connect(
        stabilization: GyroStabilizationState?, recording: Bool? = false, videoMode: Bool? = true,
        at time: Double
    ) {
        send(.connected(identity))
        send(.stabilization(stabilization))
        send(.recording(recording, at: time))
        send(.videoMode(videoMode))
    }
}
