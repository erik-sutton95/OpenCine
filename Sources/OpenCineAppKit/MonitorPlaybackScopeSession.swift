import Foundation
import Observation
import OpenCineCore
import OpenCineMedia

/// Immutable samples from the existing native source, identified by its actual publication.
public struct MonitorPlaybackScopeFrame: Sendable {
    public let revision: UInt64
    public let samples: ScopeSamples
    public init(revision: UInt64, samples: ScopeSamples) { self.revision = revision; self.samples = samples }
}

/// Owns polling and derivation for a captured player item. Native acquisition and calibration
/// supply values; no decoder, view, transfer or source lifetime is constructed here.
@available(macOS 14, *) @MainActor @Observable
public final class MonitorPlaybackScopeSession<Configuration: Equatable & Sendable> {
    @ObservationIgnored private var currentBundle = ScopeAssistBundle.empty
    public private(set) var bundle: ScopeAssistBundle {
        get { access(keyPath: \.bundle); return currentBundle }
        set { currentBundle = newValue; withMutation(keyPath: \.bundle) {} }
    }
    @ObservationIgnored private let cadence: Duration
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private let derive: @Sendable (ScopeSamples, Configuration, ScopeAssistBundle) async -> ScopeAssistBundle
    @ObservationIgnored private var item: MonitorPlaybackItemToken?
    @ObservationIgnored private var configuration: Configuration?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var closed = false
    public init(cadence: Duration,
        sleep: @escaping @MainActor (Duration) async throws -> Void = hostSleep(for:),
        derive: @escaping @Sendable (ScopeSamples, Configuration, ScopeAssistBundle) async -> ScopeAssistBundle) {
        self.cadence = cadence; self.sleep = sleep; self.derive = derive
    }
    public func synchronize(item next: MonitorPlaybackItemToken, enabled wants: Bool, configuration value: Configuration,
        read: @escaping @MainActor () async -> MonitorPlaybackScopeFrame?,
        ifCurrent: @escaping @MainActor () -> Bool) {
        guard !closed else { return }
        let before = revision
        guard ifCurrent(), !closed, revision == before else { return }
        if item == next, configuration == value, enabled == wants { return }
        let changesItem = item != next
        revision = UUID(); let captured = revision
        let previous = task; task = nil; previous?.cancel()
        guard revision == captured, !closed else { return }
        item = next; configuration = value; enabled = wants
        if changesItem || !wants { bundle = .empty }
        guard wants, current(next, revision: captured, ifCurrent: ifCurrent) else { return }
        task = Task { @MainActor [weak self] in
            var lastPublication: UInt64?
            while let self, !Task.isCancelled, self.current(next, revision: captured, ifCurrent: ifCurrent) {
                let frame = await read()
                guard !Task.isCancelled, self.current(next, revision: captured, ifCurrent: ifCurrent) else { return }
                if let frame, frame.revision != lastPublication {
                    let previous = self.bundle
                    let derived = await self.derive(frame.samples, value, previous)
                    guard !Task.isCancelled, self.current(next, revision: captured, ifCurrent: ifCurrent) else { return }
                    lastPublication = frame.revision; self.bundle = derived
                    guard self.current(next, revision: captured, ifCurrent: ifCurrent) else { return }
                }
                do { try await self.sleep(self.cadence) } catch { return }
            }
        }
    }
    private func current(_ token: MonitorPlaybackItemToken, revision captured: UUID,
        ifCurrent: @MainActor () -> Bool) -> Bool {
        guard !closed, enabled, revision == captured, item == token else { return false }
        let admitted = ifCurrent()
        return admitted && !closed && enabled && revision == captured && item == token
    }
    public func retire(item token: MonitorPlaybackItemToken) {
        guard item == token else { return }
        revision = UUID(); let captured = revision
        item = nil; configuration = nil; enabled = false
        let previous = task; task = nil; previous?.cancel()
        guard revision == captured, item == nil, !closed else { return }
        bundle = .empty
    }
    public func close() {
        guard !closed else { return }
        closed = true; revision = UUID(); item = nil; configuration = nil; enabled = false
        let previous = task; task = nil; previous?.cancel(); bundle = .empty
    }
}
