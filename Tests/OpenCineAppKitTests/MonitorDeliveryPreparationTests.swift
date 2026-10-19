import Foundation
import OpenCineAppKit
import Testing

@MainActor private final class DeliveryPreparationGate<T: Sendable> {
    private var waiting: [CheckedContinuation<T, Never>] = []
    var count: Int { waiting.count }
    func value() async -> T { await withCheckedContinuation { waiting.append($0) } }
    func release(_ value: T) { waiting.removeFirst().resume(returning: value) }
}
@MainActor @Suite struct MonitorDeliveryPreparationTests {
    typealias Model = MonitorDeliveryPreparationModel<Int, Int, String, String, Int>
    typealias Listing = MonitorDeliveryProjectListing<String, String>
    @MainActor private final class Fixture {
        let loads = DeliveryPreparationGate<Listing>(), creates = DeliveryPreparationGate<MonitorDeliveryProject<String>>()
        let waits = DeliveryPreparationGate<Bool>(), clock = DeliveryPreparationGate<Void>()
        var owned: Int?, revision = 0, restored: [Int] = [], persisted: [String] = []
        var network: Bool? = false, configured: Bool? = true, connected: Bool? = true
        var savedID: String?, sourceHook: (() -> Bool)?, persistHook: (() -> Void)?, restoreHook: (() -> Void)?
        var lut: Bool? = true, convert: Bool? = true, skipsUploaded = true
        var files: [MonitorDeliveryFileFacts] = [.init(filename: "SIMULATED.mov", sizeBytes: nil)], bakeLUT = false
        var nativeWaits: [Int] = []
        func model(preferred: MonitorDeliveryDestination? = .remoteUpload, export: Bool = true) -> Model {
            var configuration = MonitorDeliveryExportConfiguration(logTransform: 1, exportFormat: 1); configuration.bakeLUT = bakeLUT
            return .init(selection: { .init(files: self.files, cachedCount: 1, connected: nil) },
                configuration: export ? configuration : nil,
                exportOptions: export ? .init(curves: [.init(id: "1", label: "SIMULATED curve", value: 1)],
                    formats: [.init(id: "1", label: "SIMULATED format", value: 1)],
                    lutAvailable: { self.lut }, convertLogAvailable: { self.convert }, lutLabel: { nil },
                    convertHelp: "SIMULATED", convertUnavailableHelp: "SIMULATED", filename: { _ in "SIMULATED.mov" }) : nil,
                remote: .init(presentation: .init(displayName: "SIMULATED upload", progressCaption: "SIMULATED uploading"), observe: { .init(configured: self.configured, connected: self.connected,
                    onCameraNetwork: self.network, savedProjectID: self.savedID, savedProjectName: nil) },
                    load: { await self.loads.value() }, create: { _, _ in await self.creates.value() },
                    persist: { project, _ in self.persisted.append(project.id); self.persistHook?() },
                    internet: .init(needsHop: { self.network == true }, begin: {
                        self.revision += 1; self.owned = self.revision; return self.revision
                    }, owns: { self.owned == $0 }, wait: { self.nativeWaits.append($0); return await self.waits.value() },
                    restore: { if self.owned == $0 { self.restored.append($0); self.owned = nil; self.restoreHook?() } }),
                    transfer: { if self.owned != $0 { return nil }; self.revision += 1; self.owned = self.revision; return self.revision },
                    skipsUploaded: self.skipsUploaded),
                preferredDestination: preferred, sourceCurrent: { self.sourceHook?() ?? true },
                sleep: { duration in #expect(duration == .seconds(1)); await self.clock.value() })
        }
        func finish(_ model: Model) {
            model.close()
            while clock.count > 0 { clock.release(()) }
        }
    }
    private func listing(_ name: String) -> Listing {
        .init(context: "SIMULATED account", projects: [.init(id: name, name: name, uploadable: true, payload: name)])
    }
    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<1000 { if predicate() { return }; await Task.yield() }
        Issue.record("SIMULATED delivery popup did not reach the manual gate")
    }
    /// A2-72: the request carries the project picked in this popup, so a later pick elsewhere
    /// never redirects the run; a native request carries none.
    @Test func remoteRequestCarriesTheSelectedProjectAndItsContext() async {
        let fixture = Fixture(); let model = fixture.model()
        model.start(); await settle { fixture.loads.count == 1 }
        fixture.loads.release(listing("SIMULATED project"))
        await settle { !model.projectsLoading }
        let request = model.takeRequest()
        #expect(request?.project?.id == "SIMULATED project" && request?.project?.payload == "SIMULATED project")
        #expect(request?.projectContext == "SIMULATED account")
        fixture.finish(model)
        let native = fixture.model(preferred: .nativeShare)
        native.start()
        let shared = native.takeRequest()
        #expect(shared?.destination == .nativeShare && shared?.project == nil && shared?.projectContext == nil)
        fixture.finish(native)
    }
    /// A2-53: re-upload is offered only where the remote keeps an upload history.
    @Test func reuploadIsOfferedOnlyWithAnUploadHistory() {
        for history in [true, false] {
            let fixture = Fixture(); fixture.skipsUploaded = history
            let model = fixture.model()
            #expect(model.offersReupload == history)
            fixture.finish(model)
        }
    }
    @Test func optionalRemoteServiceCarriesOnlyItsDeclaredPresentation() {
        let fixture = Fixture(); let model = fixture.model()
        #expect(model.remotePresentation?.displayName == "SIMULATED upload")
        #expect(model.remotePresentation?.progressCaption == "SIMULATED uploading")
        fixture.finish(model)
    }
    /// ZIB-469: a still travels as its original, so no Bake LUT, curve or container is offered for it.
    @Test func stillsOnlySelectionOffersNoClipExport() async {
        let fixture = Fixture(); fixture.bakeLUT = true
        fixture.files = [.init(filename: "DSC_0001.JPG", sizeBytes: nil, isStill: true)]
        let model = fixture.model(preferred: .nativeShare)
        model.start()
        #expect(model.clipExportOptions == nil)
        #expect(model.configuration?.bakeLUT == false)
        model.setBakeLUT(true)
        #expect(model.configuration?.bakeLUT == false)
        #expect(model.canContinue)
        fixture.files = [.init(filename: "DSC_0001.JPG", sizeBytes: nil, isStill: true),
            .init(filename: "DSC_0002.MOV", sizeBytes: nil, isStill: false)]
        let mixed = fixture.model(preferred: .nativeShare)
        mixed.start()
        #expect(mixed.clipExportOptions != nil && mixed.configuration?.bakeLUT == true)
        fixture.finish(mixed); fixture.finish(model)
    }
    @Test func unknownExportFactsCannotEnableInventedOptions() async {
        let fixture = Fixture(); fixture.lut = nil; fixture.convert = nil
        let model = fixture.model(preferred: .nativeShare)
        model.start()
        #expect(model.selection.files.first?.sizeBytes == nil && model.selection.connected == nil)
        model.setBakeLUT(true); model.setConvertLog(true)
        #expect(model.configuration?.bakeLUT == false && model.configuration?.convertLog == false)
        #expect(model.canContinue)
        model.configuration = nil
        #expect(!model.canContinue)
        fixture.finish(model)
    }
    @Test func optionalNativeOriginalServiceNeedsNoExportOrUploadSettings() async {
        let fixture = Fixture(); fixture.configured = nil; fixture.connected = nil
        let model = fixture.model(preferred: .nativeShare, export: false)
        model.start()
        #expect(model.configuration == nil && model.exportOptions == nil && model.canContinue)
        #expect(!model.destinationEnabled(.remoteUpload))
        let request = model.takeRequest()
        #expect(request?.destination == .nativeShare && request?.configuration == nil && request?.internetLease == nil)
        fixture.finish(model)
    }
    @Test func replacementRejectsUncancellableProjectListing() async {
        let fixture = Fixture(), model = fixture.model()
        model.start(); await settle { fixture.loads.count == 1 }
        model.loadProjects(); await settle { fixture.loads.count == 2 }
        fixture.loads.release(listing("old")); for _ in 0..<20 { await Task.yield() }
        #expect(model.listing == nil && model.projectsLoading && fixture.persisted.isEmpty)
        fixture.loads.release(listing("current")); await settle { model.listing?.projects.first?.id == "current" }
        #expect(model.selectedProjectID == "current" && fixture.persisted == ["current"])
        fixture.finish(model)
    }
    @Test func sourcePredicateReplacementRejectsFalseAndTrueListingReplies() async {
        for reply in [false, true] {
            let fixture = Fixture(), model = fixture.model()
            model.start(); await settle { fixture.loads.count == 1 }
            var replace = true
            fixture.sourceHook = {
                if replace { replace = false; model.loadProjects(); return reply }
                return true
            }
            fixture.loads.release(listing("old")); await settle { fixture.loads.count == 1 }
            #expect(model.listing == nil && model.projectsLoading && fixture.persisted.isEmpty)
            fixture.loads.release(listing("current")); await settle { model.listing?.projects.first?.id == "current" }
            #expect(fixture.persisted == ["current"] && model.selectedProjectID == "current")
            fixture.finish(model)
        }
    }
    @Test func persistenceCallbackReplacementKeepsSuccessorRequest() async {
        let fixture = Fixture(), model = fixture.model()
        model.start(); await settle { fixture.loads.count == 1 }
        fixture.persistHook = { fixture.persistHook = nil; model.loadProjects() }
        fixture.loads.release(listing("old")); await settle { fixture.loads.count == 1 }
        #expect(model.listing == nil && model.projectsLoading && fixture.persisted == ["old"])
        fixture.loads.release(listing("current")); await settle { model.listing?.projects.first?.id == "current" }
        #expect(fixture.persisted == ["old", "current"] && model.selectedProjectID == "current")
        fixture.finish(model)
    }
    @Test func closeRetiresLateProjectCreation() async {
        let fixture = Fixture(), model = fixture.model()
        model.start(); await settle { fixture.loads.count == 1 }
        fixture.loads.release(listing("known")); await settle { model.listing != nil }
        model.newProjectName = "  SIMULATED new  "; model.createProject()
        await settle { fixture.creates.count == 1 }
        fixture.finish(model)
        fixture.creates.release(.init(id: "late", name: "late", uploadable: true, payload: "late"))
        for _ in 0..<20 { await Task.yield() }
        #expect(model.listing?.projects.map(\.id) == ["known"] && fixture.persisted == ["known"])
        #expect(model.selectedProjectID == "known" && !model.canContinue)
    }
    @Test func acceptedDeliveryTransfersLeaseBeforePopupClose() async {
        let fixture = Fixture(); fixture.network = true; fixture.savedID = "saved"
        let model = fixture.model()
        model.start(); model.hopToInternet(); await settle { fixture.waits.count == 1 }
        #expect(model.hopping && !model.canContinue && fixture.owned == 1)
        fixture.network = false; fixture.waits.release(true)
        await settle { !model.hopping && fixture.loads.count == 1 }
        let request = model.takeRequest()
        #expect(request?.internetLease == 2 && fixture.owned == 2 && fixture.restored.isEmpty)
        fixture.loads.release(listing("late")); for _ in 0..<20 { await Task.yield() }
        fixture.finish(model)
        #expect(fixture.owned == 2 && fixture.restored.isEmpty && fixture.persisted.isEmpty)
    }
    @Test func cancelledPopupRestoresOnlyItsOwnLeaseDespiteReentry() async {
        let fixture = Fixture(); fixture.network = true
        let model = fixture.model()
        model.start(); model.hopToInternet(); await settle { fixture.waits.count == 1 }
        fixture.restoreHook = { fixture.revision += 1; fixture.owned = fixture.revision }
        fixture.finish(model)
        #expect(fixture.restored == [1] && fixture.owned == 2)
        fixture.waits.release(true); for _ in 0..<20 { await Task.yield() }
        model.close()
        #expect(fixture.restored == [1] && fixture.owned == 2 && fixture.loads.count == 0)
    }
}
