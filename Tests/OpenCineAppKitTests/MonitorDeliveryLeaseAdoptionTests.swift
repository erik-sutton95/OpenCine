import Foundation
import OpenCineAppKit
import Testing

@MainActor private final class AdoptedDeliveryFacts {
    var current = true
    var owned: Int? = 1
    var calls: [String] = []
    var onOwns: (() -> Void)?
    var service: MonitorDeliveryRemoteService<String, Int, Int> {
        .init(
            presentation: .init(displayName: "Remote", progressCaption: "Uploading"),
            observe: {
                .init(
                    configured: true, connected: true, onCameraNetwork: false,
                    savedProjectID: "p", savedProjectName: "Project")
            }, load: { .init(context: 1, projects: []) },
            create: { _, _ in .init(id: "p", name: "Project", uploadable: true, payload: "p") },
            persist: { _, _ in self.calls.append("persist") },
            internet: .init(
                needsHop: { false },
                begin: {
                    self.calls.append("begin")
                    return 99
                },
                owns: { token in
                    let accepted = self.owned == token
                    self.onOwns?()
                    return accepted
                },
                wait: { _ in
                    self.calls.append("wait")
                    return true
                },
                restore: { token in
                    if self.owned == token {
                        self.owned = nil
                        self.calls.append("restore \(token)")
                    }
                }),
            transfer: { token in
                guard self.owned == token else { return nil }
                self.owned = token + 1
                self.calls.append("transfer \(token)")
                return token + 1
            }, skipsUploaded: false)
    }
}

/// SIMULATED approved route resume, using only the transferred lease and original content claim.
@MainActor @Suite struct MonitorDeliveryLeaseAdoptionTests {
    typealias Model = MonitorDeliveryPreparationModel<Int, Int, String, Int, Int>
    private func make(_ facts: AdoptedDeliveryFacts) -> Model {
        Model(
            selection: {
                .init(
                    files: [.init(filename: "captured.mov", sizeBytes: 1)], cachedCount: 1,
                    connected: false)
            }, configuration: nil, exportOptions: nil, remote: facts.service,
            sourceCurrent: { facts.current }, sleep: { _ in throw CancellationError() })
    }

    @Test func adoptedLeaseStartsNoSecondLeaveOrWait() {
        let facts = AdoptedDeliveryFacts()
        let model = make(facts)
        let adopted = model.adoptInternetLease(1)
        #expect(adopted && model.destination == .remoteUpload && model.step == .options)
        #expect(facts.calls.isEmpty && facts.owned == 1)
        model.close()
        #expect(facts.calls == ["restore 1"])
    }
    @Test func admittedRequestTransfersOnlyItsAdoptedLease() throws {
        let facts = AdoptedDeliveryFacts()
        let model = make(facts)
        let adopted = model.adoptInternetLease(1)
        #expect(adopted)
        model.start()
        let result = model.takeRequest()
        let request = try #require(result)
        #expect(request.internetLease == 2 && facts.owned == 2)
        #expect(facts.calls == ["transfer 1"])
        model.close()
        #expect(facts.owned == 2)
    }
    @Test func retiredCanonicalClaimCannotAdoptOrRestoreAReplacement() {
        let facts = AdoptedDeliveryFacts()
        facts.current = false
        facts.owned = 2
        let model = make(facts)
        let adopted = model.adoptInternetLease(1)
        #expect(!adopted && facts.owned == 2 && facts.calls.isEmpty)
        model.close()
        #expect(facts.owned == 2 && facts.calls.isEmpty)
    }
    @Test func replacementDuringLeaseObservationRefusesAdoption() {
        let facts = AdoptedDeliveryFacts()
        facts.onOwns = { facts.owned = 2 }
        let model = make(facts)
        let adopted = model.adoptInternetLease(1)
        #expect(!adopted && facts.owned == 2 && facts.calls.isEmpty)
        model.close()
        #expect(facts.owned == 2 && facts.calls.isEmpty)
    }
    @Test func oldPopupCloseCannotRestoreATransferredSuccessor() {
        let facts = AdoptedDeliveryFacts()
        let old = make(facts)
        let adopted = old.adoptInternetLease(1)
        #expect(adopted)
        facts.owned = 2
        let successor = make(facts)
        let successorAdopted = successor.adoptInternetLease(2)
        #expect(successorAdopted)
        old.close()
        #expect(facts.owned == 2 && facts.calls.isEmpty)
        successor.close()
        #expect(facts.owned == nil && facts.calls == ["restore 2"])
    }
    @Test func duplicateAdoptionKeepsTheOriginalCleanupLease() {
        let facts = AdoptedDeliveryFacts()
        let model = make(facts)
        let first = model.adoptInternetLease(1)
        let duplicate = model.adoptInternetLease(1)
        #expect(first && !duplicate && facts.calls.isEmpty)
        model.close()
        model.close()
        #expect(facts.calls == ["restore 1"])
        let closed = model.adoptInternetLease(1)
        #expect(!closed)
    }
}
