import Foundation
import OpenCineAppKit
import OpenCineMedia
import Testing

@MainActor private final class PlaybackScopeGate {
    var started = false
    private var held: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { held = $0 } }
    func release() { let previous = held; held = nil; previous?.resume() }
}

@MainActor @Suite struct MonitorPlaybackScopeSessionTests {
    private func settled(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<300 { if predicate() { return true }; await Task.yield() }; return predicate()
    }
    private func item(_ revision: UInt64, owner: UUID) -> MonitorPlaybackItemToken { .init(owner: owner, revision: revision) }

    @Test func heldSourceReadCannotPublishIntoReplacementItem() async {
        guard #available(macOS 14, *) else { return }
        let gate = PlaybackScopeGate(), clock = PlaybackScopeGate(); defer { gate.release(); clock.release() }
        let session = MonitorPlaybackScopeSession<Int>(cadence: .milliseconds(84), sleep: { _ in await clock.wait() },
            derive: { _, value, _ in .init(revision: UInt64(value)) })
        defer { session.close() }; let owner = UUID()
        session.synchronize(item: item(1, owner: owner), enabled: true, configuration: 1,
            read: { await gate.wait(); return .init(revision: 1, samples: .empty) }, ifCurrent: { true })
        #expect(await settled { gate.started })
        session.synchronize(item: item(2, owner: owner), enabled: true, configuration: 2,
            read: { .init(revision: 2, samples: .empty) }, ifCurrent: { true })
        #expect(await settled { session.bundle.revision == 2 }); gate.release()
        for _ in 0..<10 { await Task.yield() }; #expect(session.bundle.revision == 2)
    }

    @Test func heldDerivationCannotOverwriteNewCalibration() async {
        guard #available(macOS 14, *) else { return }
        let gate = PlaybackScopeGate(), clock = PlaybackScopeGate(); defer { gate.release(); clock.release() }
        let session = MonitorPlaybackScopeSession<Int>(cadence: .milliseconds(84), sleep: { _ in await clock.wait() },
            derive: { _, value, _ in if value == 1 { await gate.wait() }; return .init(revision: UInt64(value)) })
        defer { session.close() }; let token = item(1, owner: UUID())
        session.synchronize(item: token, enabled: true, configuration: 1,
            read: { .init(revision: 1, samples: .empty) }, ifCurrent: { true })
        #expect(await settled { gate.started })
        session.synchronize(item: token, enabled: true, configuration: 2,
            read: { .init(revision: 1, samples: .empty) }, ifCurrent: { true })
        #expect(await settled { session.bundle.revision == 2 }); gate.release()
        for _ in 0..<10 { await Task.yield() }; #expect(session.bundle.revision == 2)
    }

    @Test func sameNativePublicationDerivesOnceAndUsesOriginalCadence() async {
        guard #available(macOS 14, *) else { return }
        var clocks: [PlaybackScopeGate] = [], reads = 0
        defer { clocks.forEach { $0.release() } }
        let session = MonitorPlaybackScopeSession<Int>(cadence: .milliseconds(84), sleep: { duration in
            #expect(duration == .milliseconds(84)); let gate = PlaybackScopeGate(); clocks.append(gate); await gate.wait()
        }, derive: { _, _, previous in .init(revision: previous.revision + 1) })
        defer { session.close() }
        session.synchronize(item: item(1, owner: UUID()), enabled: true, configuration: 1,
            read: { reads += 1; return .init(revision: 9, samples: .empty) }, ifCurrent: { true })
        #expect(await settled { clocks.count == 1 }); clocks[0].release()
        #expect(await settled { clocks.count == 2 }); #expect(reads == 2 && session.bundle.revision == 1)
    }

    @Test func admissionReentryClosesBeforeNativeRead() async {
        guard #available(macOS 14, *) else { return }
        var reads = 0
        let session = MonitorPlaybackScopeSession<Int>(cadence: .milliseconds(84), derive: { _, _, _ in .init(revision: 1) })
        session.synchronize(item: item(1, owner: UUID()), enabled: true, configuration: 1,
            read: { reads += 1; return .init(revision: 1, samples: .empty) }, ifCurrent: { session.close(); return true })
        for _ in 0..<10 { await Task.yield() }; #expect(reads == 0 && session.bundle == .empty)
    }

    @Test func closeDuringDerivationRetiresPublicationAndClock() async {
        guard #available(macOS 14, *) else { return }
        let gate = PlaybackScopeGate(); defer { gate.release() }; var clocks = 0
        let session = MonitorPlaybackScopeSession<Int>(cadence: .milliseconds(84), sleep: { _ in clocks += 1 },
            derive: { _, _, _ in await gate.wait(); return .init(revision: 9) })
        session.synchronize(item: item(1, owner: UUID()), enabled: true, configuration: 1,
            read: { .init(revision: 1, samples: .empty) }, ifCurrent: { true })
        #expect(await settled { gate.started }); session.close(); gate.release()
        for _ in 0..<10 { await Task.yield() }; #expect(session.bundle == .empty && clocks == 0)
    }
}
