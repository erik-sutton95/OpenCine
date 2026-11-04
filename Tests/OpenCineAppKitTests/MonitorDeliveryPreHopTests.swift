import Foundation
import OpenCineAppKit
import Testing

@MainActor private final class PreHopGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var count: Int { waiting.count }
    func enter() async { await withCheckedContinuation { waiting.append($0) } }
    func release(_ index: Int = 0) { waiting.remove(at: index).resume() }
}

@MainActor private final class PreHopFacts {
    var current = true
    var onCameraNetwork = true
    var calls: [String] = []
    var owned: Int?
    var revision = 0
    var polls = 0
    var refuses = false
    var service: MonitorDeliveryRemoteService<String, Int, Int> {
        .init(
            presentation: .init(displayName: "Remote", progressCaption: "Uploading"),
            observe: {
                .init(
                    configured: true, connected: true, onCameraNetwork: self.onCameraNetwork,
                    savedProjectID: "project", savedProjectName: "Project")
            },
            load: {
                self.calls.append("projects")
                return .init(
                    context: 1,
                    projects: [
                        .init(id: "project", name: "Project", uploadable: true, payload: "project")
                    ])
            },
            create: { name, _ in .init(id: name, name: name, uploadable: true, payload: name) },
            persist: { _, _ in self.calls.append("persist") },
            internet: .init(
                needsHop: { self.onCameraNetwork },
                begin: {
                    if self.refuses {
                        self.calls.append("refused")
                        return nil
                    }
                    self.calls.append("begin")
                    self.revision += 1
                    self.owned = self.revision
                    self.onCameraNetwork = false
                    return self.revision
                }, owns: { self.owned == $0 },
                wait: { _ in
                    self.calls.append("wait")
                    return true
                },
                restore: { lease in
                    guard self.owned == lease else { return }
                    self.calls.append("restore \(lease)")
                    self.owned = nil
                }),
            transfer: { $0 }, skipsUploaded: false)
    }
}

/// SIMULATED cache completions use the popup's existing hop task and real shared request owner.
@MainActor @Suite struct MonitorDeliveryPreHopTests {
    typealias Model = MonitorDeliveryPreparationModel<Int, Int, String, Int, Int>

    @Test func capturedCacheCompletesBeforeTheFirstRouteLeave() async {
        let facts = PreHopFacts()
        let gate = PreHopGate()
        let model = make(facts) {
            facts.calls.append("cache")
            await gate.enter()
            facts.calls.append("cached")
        }
        await settle { facts.polls == 1 }
        model.hopToInternet()
        await settle { gate.count == 1 }
        #expect(model.hopping && facts.calls == ["cache"] && facts.owned == nil)
        gate.release()
        await settle { model.listing != nil }
        #expect(facts.calls == ["cache", "cached", "begin", "wait", "projects", "persist"])
        #expect(!model.hopping && model.selectedProjectID == "project")
        model.close()
        #expect(facts.calls.last == "restore 1")
    }

    @Test func retiredSourceCannotHopAfterAnEnteredCacheCompletion() async {
        let facts = PreHopFacts()
        let gate = PreHopGate()
        let model = make(facts) {
            facts.calls.append("cache")
            await gate.enter()
            facts.calls.append("cleanup")
        }
        await settle { facts.polls == 1 }
        model.hopToInternet()
        await settle { gate.count == 1 }
        facts.current = false
        gate.release()
        await settle { facts.calls == ["cache", "cleanup"] }
        #expect(facts.owned == nil && model.listing == nil && model.projectsError == nil)
        model.close()
    }

    @Test func popupCloseAllowsEnteredCleanupWithoutLeavingOrPublishing() async {
        let facts = PreHopFacts()
        let gate = PreHopGate()
        let model = make(facts) {
            facts.calls.append("cache")
            await gate.enter()
            facts.calls.append("cleanup")
        }
        await settle { facts.polls == 1 }
        model.hopToInternet()
        await settle { gate.count == 1 }
        model.close()
        gate.release()
        await settle { facts.calls == ["cache", "cleanup"] }
        #expect(facts.owned == nil && model.listing == nil && model.projectsError == nil)
    }

    @Test func refusedCacheDoesNotAcquireARouteLease() async {
        struct Refusal: LocalizedError { var errorDescription: String? { "Original unavailable." } }
        let facts = PreHopFacts()
        let model = make(facts) {
            facts.calls.append("cache")
            throw Refusal()
        }
        await settle { facts.polls == 1 }
        model.hopToInternet()
        await settle { model.projectsError != nil }
        #expect(model.projectsError == "Original unavailable." && !model.hopping)
        #expect(facts.calls == ["cache"] && facts.owned == nil)
        model.close()
    }

    /// A2-16: while another hop holds the route, begin refuses; the popup says why, stays on the
    /// camera network and lists nothing.
    @Test func aRefusedRouteSaysWhyAndNeverLeaves() async {
        let facts = PreHopFacts()
        facts.refuses = true
        let model = make(facts) { facts.calls.append("cache") }
        await settle { facts.polls == 1 }
        model.hopToInternet()
        await settle { model.projectsError != nil }
        #expect(model.projectsError == "Couldn't leave the camera's Wi‑Fi while another network switch is running.")
        #expect(!model.hopping && model.listing == nil && facts.owned == nil)
        #expect(facts.calls == ["cache", "refused"] && facts.onCameraNetwork)
        model.close()
    }

    @Test func oldPreflightCannotReleaseOrPublishTheSuccessorHop() async {
        let facts = PreHopFacts()
        let gate = PreHopGate()
        var entered = 0
        let model = make(facts) {
            entered += 1
            let captured = entered
            facts.calls.append("cache \(captured)")
            await gate.enter()
            facts.calls.append("cleanup \(captured)")
        }
        await settle { facts.polls == 1 }
        model.hopToInternet()
        await settle { gate.count == 1 }
        await settle { facts.polls == 1 }
        model.hopToInternet()
        await settle { gate.count == 2 }
        gate.release()
        await settle { facts.calls.contains("cleanup 1") }
        #expect(model.hopping && facts.owned == nil && model.projectsError == nil)
        gate.release()
        await settle { model.listing != nil }
        #expect(
            facts.calls == [
                "cache 1", "cache 2", "cleanup 1", "cleanup 2", "begin", "wait", "projects",
                "persist",
            ])
        model.close()
    }

    @Test func aPreflightCallbackCannotBorrowAReplacementSource() async {
        let facts = PreHopFacts()
        let model = make(facts) {
            facts.calls.append("cache")
            facts.current = false
        }
        await settle { facts.polls == 1 }
        model.hopToInternet()
        await settle { facts.calls == ["cache"] }
        for _ in 0..<10 { await Task.yield() }
        #expect(facts.owned == nil && model.listing == nil && model.projectsError == nil)
        model.close()
    }

    @Test func nilPreflightKeepsTheOriginalSynchronousRouteAdmission() async {
        let facts = PreHopFacts()
        let model = Model(
            selection: selection, configuration: nil, exportOptions: nil,
            remote: facts.service, preferredDestination: .remoteUpload,
            sourceCurrent: { facts.current },
            sleep: { _ in
                facts.polls += 1
                throw CancellationError()
            })
        model.start()
        await settle { facts.polls == 1 }
        model.hopToInternet()
        #expect(facts.calls == ["begin"] && facts.owned == 1)
        await settle { model.listing != nil }
        #expect(facts.calls == ["begin", "wait", "projects", "persist"])
        model.close()
    }

    /// A2-05: the shared delivery owner's preflight caches every original before the route
    /// leaves the camera network, as one captured run of the app's delivery model.
    @Test func deliveryOwnerCachesEveryOriginalBeforeTheRouteLeaves() async {
        let facts = PreHopFacts()
        let delivery = MonitorDeliveryModel<MonitorDeliveryBatchProgress, String, Int>()
        var cached: Set<String> = []
        let originals = MonitorDeliveryOriginalService<String>(
            available: { cached.contains($0) },
            acquire: {
                facts.calls.append("acquire \($0)")
                cached.insert($0)
            }, progress: { _ in nil })
        let model = make(facts) {
            try await delivery.cacheBeforeInternetHop(
                records: ["A", "B"], originals: originals, source: .init { facts.current },
                filename: { $0 }, completion: "cached", progress: { $0 })
        }
        await settle { facts.polls == 1 }
        model.hopToInternet()
        await settle { model.listing != nil }
        #expect(facts.calls == ["acquire A", "acquire B", "begin", "wait", "projects", "persist"])
        #expect(!delivery.state.running && delivery.state.toast == nil)
        model.close()
        delivery.close()
    }

    @Test func uncachedOriginalKeepsTheRouteOnTheCameraNetwork() async {
        let facts = PreHopFacts()
        let delivery = MonitorDeliveryModel<MonitorDeliveryBatchProgress, String, Int>()
        let originals = MonitorDeliveryOriginalService<String>(
            available: { _ in false }, acquire: { facts.calls.append("acquire \($0)") },
            progress: { _ in nil })
        let model = make(facts) {
            try await delivery.cacheBeforeInternetHop(
                records: ["A"], originals: originals, source: .init { facts.current },
                filename: { $0 }, completion: "cached", progress: { $0 })
        }
        await settle { facts.polls == 1 }
        model.hopToInternet()
        await settle { model.projectsError != nil }
        #expect(model.projectsError == MonitorDeliveryCacheError.uncached(1).errorDescription)
        #expect(facts.calls == ["acquire A"] && facts.owned == nil && !model.hopping)
        model.close()
        delivery.close()
    }

    /// Owner report 2026-10-29: when the camera stops answering mid-cache, the hop says so.
    @Test func originalTheCameraStoppedSendingSaysTheCameraStoppedResponding() async {
        let facts = PreHopFacts()
        let delivery = MonitorDeliveryModel<MonitorDeliveryBatchProgress, String, Int>()
        let originals = MonitorDeliveryOriginalService<String>(
            available: { _ in false }, acquire: { facts.calls.append("acquire \($0)") },
            progress: { _ in nil }, cameraStoppedResponding: { _ in true })
        let model = make(facts) {
            try await delivery.cacheBeforeInternetHop(
                records: ["A"], originals: originals, source: .init { facts.current },
                filename: { $0 }, completion: "cached", progress: { $0 })
        }
        await settle { facts.polls == 1 }
        model.hopToInternet()
        await settle { model.projectsError != nil }
        #expect(
            model.projectsError
                == "The camera stopped responding while caching 1 clip(s). Reconnect and try again.")
        #expect(facts.calls == ["acquire A"] && facts.owned == nil && !model.hopping)
        model.close()
        delivery.close()
    }

    private func make(_ facts: PreHopFacts, preflight: @escaping () async throws -> Void) -> Model {
        let model = Model(
            selection: selection, configuration: nil, exportOptions: nil,
            remote: facts.service, preferredDestination: .remoteUpload,
            sourceCurrent: { facts.current }, beforeInternetHop: preflight,
            sleep: { _ in
                facts.polls += 1
                throw CancellationError()
            })
        model.start()
        return model
    }
    private var selection: () -> MonitorDeliverySelectionFacts {
        {
            .init(
                files: [.init(filename: "original.mov", sizeBytes: 12)], cachedCount: 0,
                connected: true)
        }
    }
    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        Issue.record("SIMULATED pre-hop cache did not reach its controlled completion")
    }
}
