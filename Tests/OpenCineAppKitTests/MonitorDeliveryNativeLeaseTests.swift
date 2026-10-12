import Foundation
import OpenCineAppKit
import Testing

@MainActor private final class NativeLeaseGate {
    var waiter: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { waiter = $0 } }
    func release() {
        let entered = waiter
        waiter = nil
        entered?.resume()
    }
}
@MainActor private final class NativeLeaseFacts {
    var current = true
    var owned: Int? = 1
    var calls: [String] = []
    var entered: NativeLeaseGate?
    var restoring: NativeLeaseGate?
    var completed = false
    var onTransfer: (() -> Void)?
    var internet: MonitorDeliveryInternetService<Int> {
        .init(
            needsHop: { true },
            begin: {
                self.calls.append("begin")
                return 99
            },
            owns: { self.owned == $0 },
            wait: { _ in
                self.calls.append("wait")
                return true
            },
            restoreEntered: { token in
                self.calls.append("restore-start \(token)")
                if let gate = self.restoring { await gate.wait() }
                if self.owned == token {
                    self.owned = nil
                    self.calls.append("restore \(token)")
                }
            },
            restore: { token in
                if self.owned == token {
                    self.owned = nil
                    self.calls.append("restore \(token)")
                }
            })
    }
    var remote: MonitorDeliveryRemoteService<String, Int, Int> {
        .init(
            presentation: .init(displayName: "Remote", progressCaption: "Upload"),
            observe: {
                .init(
                    configured: true, connected: true, onCameraNetwork: false, savedProjectID: "p",
                    savedProjectName: "Project")
            },
            load: { .init(context: 1, projects: []) },
            create: { _, _ in .init(id: "p", name: "Project", uploadable: true, payload: "p") },
            persist: { _, _ in }, internet: internet,
            transfer: { token in
                self.onTransfer?()
                guard self.owned == token else { return nil }
                self.owned = token + 1
                self.calls.append("transfer \(token)")
                return token + 1
            }, skipsUploaded: false)
    }
}

/// SIMULATED already-approved setup route. Native destinations use the same captured run.
@MainActor @Suite struct MonitorDeliveryNativeLeaseTests {
    typealias Preparation = MonitorDeliveryPreparationModel<Int, Int, String, Int, Int>
    typealias Batch = MonitorDeliveryModel<
        MonitorDeliveryBatchProgress, MonitorDeliveryBatchOutcome<String>, String
    >
    private func request(_ facts: NativeLeaseFacts) -> MonitorDeliveryPreparedRequest<
        Int, Int, String, Int, Int
    >? {
        let popup = Preparation(
            selection: {
                .init(
                    files: [.init(filename: "original.mov", sizeBytes: 1)], cachedCount: 1,
                    connected: false)
            },
            configuration: nil, exportOptions: nil, remote: facts.remote,
            sourceCurrent: { facts.current }, sleep: { _ in throw CancellationError() })
        guard popup.adoptInternetLease(1) else { return nil }
        popup.start()
        popup.selectDestination(.nativeShare)
        let result = popup.takeRequest()
        popup.close()
        return result
    }
    private func batch(
        _ facts: NativeLeaseFacts, lease: Int?,
        action: MonitorDeliveryPostExportAction = .systemShare
    ) async -> MonitorDeliveryBatchOutcome<String> {
        await Batch.runBatch(
            records: [1], destination: .nativeShare, action: action,
            admission: .init { facts.current },
            originals: .init(
                available: { _ in true }, acquire: { _ in facts.calls.append("cache") },
                progress: { _ in nil }),
            exporter: .init(release: { facts.calls.append("release \($0)") }) { _, _ in
                facts.calls.append("prepare")
                if let gate = facts.entered { await gate.wait() }
                return "file"
            },
            share: { files in
                facts.calls.append("stage")
                return .init(urls: files, cleanup: "staging")
            },
            photos: .init { _ in
                facts.calls.append("save")
                return true
            },
            upload: .init { _, _ in facts.calls.append("upload") }, internet: facts.internet,
            lease: lease,
            filename: { _ in "original.mov" }, progress: { _ in })
    }
    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        Issue.record("Manual native/route gate was not reached")
    }
    @Test func nativeShareTransfersSetupLeaseAndJoinsRestore() async throws {
        let facts = NativeLeaseFacts()
        facts.restoring = NativeLeaseGate()
        let value = request(facts)
        let accepted = try #require(value)
        #expect(
            accepted.destination == .nativeShare && accepted.internetLease == 2 && facts.owned == 2)
        let task = Task {
            let result = await batch(facts, lease: accepted.internetLease)
            facts.completed = true
            return result
        }
        await settle { facts.restoring?.waiter != nil }
        #expect(
            !facts.completed
                && facts.calls == [
                    "transfer 1", "prepare", "stage", "release file", "restore-start 2",
                ])
        facts.restoring?.release()
        let result = await task.value
        guard case .share(let urls, _, let cleanup) = result else {
            Issue.record("Missing native Share")
            return
        }
        #expect(urls == ["file"] && cleanup == "staging" && facts.owned == nil)
        #expect(facts.calls.last == "restore 2" && facts.completed)
    }
    @Test func nativePhotosTransfersSetupLeaseWithoutBeginOrUpload() async throws {
        let facts = NativeLeaseFacts()
        let value = request(facts)
        let accepted = try #require(value)
        let result = await batch(facts, lease: accepted.internetLease, action: .saveToPhotos)
        guard case .savedToPhotos(let count) = result else {
            Issue.record("Missing native Photos")
            return
        }
        #expect(count == 1 && facts.owned == nil)
        #expect(
            facts.calls == [
                "transfer 1", "prepare", "save", "release file", "restore-start 2", "restore 2",
            ])
    }
    @Test func cancelledEnteredPreparationReleasesBeforeCapturedRestore() async throws {
        let facts = NativeLeaseFacts()
        facts.entered = NativeLeaseGate()
        let value = request(facts)
        let accepted = try #require(value)
        let task = Task { await batch(facts, lease: accepted.internetLease) }
        await settle { facts.entered?.waiter != nil }
        task.cancel()
        facts.entered?.release()
        let result = await task.value
        guard case .failed(let message) = result else {
            Issue.record("Missing canceled result")
            return
        }
        #expect(message == "Cancelled." && facts.owned == nil)
        #expect(
            facts.calls == [
                "transfer 1", "prepare", "release file", "restore-start 2", "restore 2",
            ])
    }
    @Test func routeABAKeepsSuccessorDuringLateNativeCompletion() async throws {
        let facts = NativeLeaseFacts()
        facts.entered = NativeLeaseGate()
        let value = request(facts)
        let accepted = try #require(value)
        let task = Task { await batch(facts, lease: accepted.internetLease) }
        await settle { facts.entered?.waiter != nil }
        facts.current = false
        facts.owned = 3
        facts.entered?.release()
        let result = await task.value
        guard case .failed = result else {
            Issue.record("Missing retired result")
            return
        }
        #expect(
            facts.owned == 3
                && facts.calls == ["transfer 1", "prepare", "release file", "restore-start 2"])
    }
    @Test func localNoLeaseDoesNotBeginRestoreOrUpload() async {
        let facts = NativeLeaseFacts()
        facts.owned = nil
        let result = await batch(facts, lease: nil)
        guard case .share = result else {
            Issue.record("Missing direct native result")
            return
        }
        #expect(facts.calls == ["prepare", "stage", "release file"])
    }
    @Test func refusedSetupTransferDoesNotRestoreSuccessor() {
        let facts = NativeLeaseFacts()
        facts.onTransfer = { facts.owned = 3 }
        let refused = request(facts)
        #expect(refused == nil && facts.owned == 3 && facts.calls.isEmpty)
    }
}
