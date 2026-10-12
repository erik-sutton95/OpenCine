import Foundation
import OpenCineAppKit
import Testing

@MainActor private final class StillsFacts {
    var exported: [String] = []
    var released: [String] = []
}
@MainActor private final class ChromeGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var count: Int { waiting.count }
    func enter() async { await withCheckedContinuation { waiting.append($0) } }
    func release() { waiting.removeFirst().resume() }
}

/// SIMULATED records and ports over the actual shared batch and delivery owner.
@MainActor @Suite struct MonitorDeliveryStillsAndChromeTests {
    typealias Model = MonitorDeliveryModel<MonitorDeliveryBatchProgress, MonitorDeliveryBatchOutcome<String>, String>

    /// A2-06: a still is delivered as its cached original, never through the movie exporter,
    /// and a borrowed original is never released as if it were a transient export.
    @Test func stillOriginalsSkipTheExporterAndAreNeverReleased() async {
        let facts = StillsFacts()
        let outcome = await Model.runBatch(
            records: ["CLIP.MOV", "PHOTO.JPG"], destination: .nativeShare, action: .systemShare,
            admission: .init { true },
            originals: .init(available: { _ in true }, acquire: { _ in }, progress: { _ in nil }),
            exporter: .init(
                original: { $0.hasSuffix(".JPG") ? "original/" + $0 : nil },
                release: { facts.released.append($0) },
                prepare: { record, _ in
                    facts.exported.append(record)
                    return "export/" + record
                }),
            share: { .init(urls: $0) }, photos: nil,
            internet: Optional<MonitorDeliveryInternetService<Int>>.none, filename: { $0 }, progress: { _ in })
        guard case .share(let urls, _, _) = outcome else {
            Issue.record("Expected a share outcome, got \(outcome)")
            return
        }
        #expect(urls == ["export/CLIP.MOV", "original/PHOTO.JPG"])
        #expect(facts.exported == ["CLIP.MOV"])
        #expect(facts.released == ["export/CLIP.MOV"])
    }

    /// A2-04: the root chrome yields while any media surface is mounted; a surface always
    /// shows the run and its outcome.
    @Test func rootChromeYieldsToMountedSurfaces() async {
        let model = Model(sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        defer { model.close() }
        let gate = ChromeGate()
        model.begin { progress in
            progress(.init(destination: .nativeShare, totalClips: 1, clipIndex: 1, clipFraction: 0.5))
            await gate.enter()
            return .init(.failed(message: "SIMULATED failure"), toast: "SIMULATED failure")
        }
        for _ in 0..<1000 where gate.count == 0 { await Task.yield() }
        #expect(model.state.progress(in: .root) != nil)
        model.enterLocalOverlayContext()
        #expect(model.state.progress(in: .root) == nil)
        #expect(model.state.progress(in: .surface) != nil)
        gate.release()
        for _ in 0..<1000 where model.state.toast == nil { await Task.yield() }
        #expect(model.state.toast(in: .surface) == "SIMULATED failure")
        #expect(model.state.toast(in: .root) == nil)
        model.exitLocalOverlayContext()
        #expect(model.state.toast(in: .root) == "SIMULATED failure")
        #expect(model.state.progress(in: .root) == nil)
    }
}
