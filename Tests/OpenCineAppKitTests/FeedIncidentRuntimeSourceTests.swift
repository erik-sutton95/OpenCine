import Foundation
@testable import OpenCineAppKit
import OpenCineMedia
import XCTest

/// SIMULATED serial-writer scheduling; exercises the production recorder and disk stores.
final class FeedIncidentRuntimeSourceTests: XCTestCase {
    func testReplacementFinalizesLivePredecessorOnceAndRejectsLateCalls() throws {
        let h = try Harness()
        defer { h.remove() }
        let oldID = "20000000-0000-4000-8000-000000000001"
        let currentID = "20000000-0000-4000-8000-000000000002"
        let old = h.runtime.beginBoundSession(context(oldID))
        old.ingestSnapshot(stall())
        h.flush()
        let current = h.runtime.beginBoundSession(context(currentID))
        XCTAssertFalse(old.isCurrent)
        XCTAssertTrue(current.isCurrent)
        h.flush()
        old.endSession(now: 100)
        old.noteExhausted(now: 100)
        old.ingestSnapshot(stall(now: 100))
        current.ingestSnapshot(stall(now: 6))
        h.flush()
        let predecessor = try XCTUnwrap(h.bundles.first { $0.header.sessionID == oldID })
        XCTAssertEqual(predecessor.header.outcome, .userEnded)
        XCTAssertEqual(predecessor.header.endedAtMonotonic, 5)
        let summaries = FeedSessionSummaryStore.load(root: h.root)
        XCTAssertEqual(summaries.filter { $0.sessionID == oldID }.count, 1)
        XCTAssertEqual(summaries.first { $0.sessionID == oldID }?.outcome, "ended")
        XCTAssertEqual(summaries.first { $0.sessionID == currentID }?.outcome, "live")
        XCTAssertEqual(h.bundles.first { $0.header.sessionID == currentID }?.header.outcome, .open)
        current.endSession(now: 7)
        h.flush()
        XCTAssertEqual(h.bundles.first { $0.header.sessionID == oldID }, predecessor)
        XCTAssertEqual(
            FeedSessionSummaryStore.load(root: h.root).first { $0.sessionID == currentID }?.outcome,
            "ended")
    }

    func testRetiredDrainCannotConsumeSuccessorBeforeBegin() throws {
        let h = try Harness()
        defer { h.remove() }
        h.queue.suspend()
        let old = h.runtime.beginBoundSession(context("old"))
        old.ingestSnapshot(stall())
        let current = h.runtime.beginBoundSession(context("current"))
        current.noteDecoderGeneration(22)
        current.noteSocketGeneration(33)
        current.ingestSnapshot(stall())
        h.queue.resume()
        h.flush()
        let bundle = try XCTUnwrap(h.bundles.single)
        XCTAssertEqual(bundle.header.sessionID, "current")
        XCTAssertEqual(bundle.header.decoderGeneration, 22)
        XCTAssertEqual(bundle.header.socketGeneration, 33)
        XCTAssertEqual(bundle.header.outcome, .open)
    }

    func testRetiredCallbacksCannotMutateReusedSessionID() throws {
        let h = try Harness()
        defer { h.remove() }
        let old = h.runtime.beginBoundSession(context("10000000-0000-4000-8000-000000000001"))
        h.flush()
        let current = h.runtime.beginBoundSession(context("10000000-0000-4000-8000-000000000001"))
        current.ingestSnapshot(stall())
        h.flush()
        old.ingestSnapshot(stall(now: 100))
        old.recordBreadcrumb(.init(monotonicAt: 5, kind: .settingsEnter, detail: "retired"))
        old.recordRepair(.init(monotonicAt: 5, action: "session", phase: .requested))
        old.noteTestSource(.faultInjection)
        old.noteDecoderGeneration(99)
        old.noteSocketGeneration(99)
        old.noteUnexpectedDisconnect(now: 5)
        old.noteExhausted(now: 5)
        old.endSession(now: 5)
        h.flush()
        var bundle = try XCTUnwrap(h.bundles.single)
        XCTAssertEqual(bundle.header.outcome, .open)
        XCTAssertEqual(bundle.header.testSource, .manual)
        XCTAssertTrue(bundle.breadcrumbs.isEmpty)
        XCTAssertTrue(bundle.repairs.isEmpty)
        current.ingestSnapshot(stall(now: 6))
        current.endSession(now: 7)
        h.flush()
        bundle = try XCTUnwrap(h.bundles.single)
        XCTAssertEqual(bundle.header.outcome, .userEnded)
        XCTAssertNotEqual(bundle.header.decoderGeneration, 99)
        XCTAssertNotEqual(bundle.header.socketGeneration, 99)
        XCTAssertEqual(FeedSessionSummaryStore.load(root: h.root).first?.outcome, "ended")
        XCTAssertEqual(FeedSessionSummaryStore.load(root: h.root).first?.testSource, .manual)
    }

    func testEndPreservesAdmittedSnapshotAndRejectsLateProducer() throws {
        let h = try Harness()
        defer { h.remove() }
        h.queue.suspend()
        let source = h.runtime.beginBoundSession(context("ending"))
        source.ingestSnapshot(stall())
        source.endSession(now: 5)
        source.noteExhausted(now: 6)
        source.ingestSnapshot(stall(now: 100))
        h.queue.resume()
        h.flush()
        let bundle = try XCTUnwrap(h.bundles.single)
        XCTAssertEqual(bundle.header.sessionID, "ending")
        XCTAssertEqual(bundle.header.outcome, .userEnded)
        XCTAssertEqual(bundle.header.endedAtMonotonic, 5)
    }

    func testLegacySequentialSessionRemainsUsable() throws {
        let h = try Harness()
        defer { h.remove() }
        h.runtime.beginSession(context("legacy"))
        h.runtime.ingestSnapshot(stall())
        h.runtime.endSession(now: 5)
        h.flush()
        XCTAssertEqual(h.bundles.single?.header.sessionID, "legacy")
        XCTAssertEqual(h.bundles.single?.header.outcome, .userEnded)
    }

    private func context(_ id: String) -> FeedIncidentSessionContext {
        .init(sessionID: id, appVersion: "1", appBuild: "1", sourceRevision: "test",
              osName: "simulated", osVersion: "1", hardwareClass: "test", cameraFamily: "test",
              testSource: .manual)
    }

    private func stall(now: Double = 4) -> FeedIncidentSnapshot {
        .init(monotonicNow: now, wallClock: Date(),
              ages: .init(accessUnitAge: 0.04, decodeAcceptAge: 0.04,
                          decodedOutputAge: 3, presentAge: 3),
              lifecycle: .init(connected: true, liveEstablished: true))
    }

    private final class Harness {
        let root: URL
        let queue = DispatchQueue(label: "test.incident.writer")
        let runtime: FeedIncidentRuntime
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let defaults = UserDefaults(suiteName: "test.incident.\(UUID().uuidString)")!
            let reporting = ReliabilityReporting(host: TestDiagnostics.host,
                consent: ReliabilityReportingConsent(defaults: defaults),
                dsn: ReliabilityReportingDSN { [] },
                gate: ReliabilityReportingGate(cameraIPv4Prefix: "192.0.2."),
                origin: FeedIncidentOrigin(derivesTestSource: false, verification: false,
                    buildIdentity: nil, injectionActivated: { false }), sink: RecordingSink())
            runtime = FeedIncidentRuntime(
                reporting: reporting, directory: root, writerQueue: queue, clock: { 5 })
        }
        var bundles: [FeedIncidentBundle] { FeedIncidentStore(directory: root, product: "test").loadAll() }
        func flush() { queue.sync {} }
        func remove() { flush(); try? FileManager.default.removeItem(at: root) }
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
