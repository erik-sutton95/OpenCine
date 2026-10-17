#if os(iOS)
import Foundation
@testable import OpenCineAppKit
import OpenCineAppKitApple
import OpenCineFrameIO
import OpenCineFrameIOApple
import Testing

@MainActor struct FrameioAccountModelTests {
    private let namespace = FrameioHostNamespace(
        keychainService: "OpenCineTests.frameio", destinationKey: "tests.frameio.destination",
        historyKey: "tests.frameio.history")
    private let listing = FrameioProjectListing(
        accountID: "acct", workspaceID: "ws", workspaceName: "Studio",
        projects: [
            try! JSONDecoder().decode(
                FrameioProject.self, from: Data(#"{"id":"p1","name":"Shoot","root_folder_id":"root1"}"#.utf8))
        ])

    private func defaults() -> UserDefaults {
        let suite = "FrameioAccountModelTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private func request(
        project: FrameioProject?, reupload: Bool
    ) -> MonitorDeliveryPreparedRequest<Int, Int, FrameioProject, FrameioProjectListing, Int> {
        var configuration = MonitorDeliveryExportConfiguration(logTransform: 0, exportFormat: 0)
        configuration.forceReupload = reupload
        return .init(
            destination: .remoteUpload, configuration: configuration, action: .systemShare,
            internetLease: nil,
            project: project.map { .init(id: $0.id, name: $0.name, uploadable: true, payload: $0) },
            projectContext: project == nil ? nil : listing)
    }

    @Test func destinationIsKeptUnderTheAppsKey() throws {
        let defaults = defaults()
        let model = FrameioAccountModel(namespace: namespace, configuration: nil, defaults: defaults)
        model.persist(listing.projects[0], in: listing)
        let raw = try #require(defaults.data(forKey: namespace.destinationKey))
        let saved = try JSONDecoder().decode(FrameioDestination.self, from: raw)
        #expect(saved.projectID == "p1" && saved.folderID == "root1" && saved.accountID == "acct")
        #expect(
            FrameioAccountModel(namespace: namespace, configuration: nil, defaults: defaults)
                .destinations.loaded == saved)
    }

    @Test func pickedProjectWinsOverTheSavedDestination() async throws {
        let model = FrameioAccountModel(namespace: namespace, configuration: nil, defaults: defaults())
        model.destinations.persist(
            .init(accountID: "acct", workspaceID: "ws", projectID: "old", projectName: "Old", folderID: "f0"))
        let picked = try await model.destination(for: listing.projects[0], in: listing)
        #expect(picked.projectID == "p1")
        let saved = try await model.destination(for: nil, in: nil)
        #expect(saved.projectID == "old")
    }

    @Test func runHistoryPersistsUnderTheAppsHistoryKey() {
        let defaults = defaults()
        let model = FrameioAccountModel(namespace: namespace, configuration: nil, defaults: defaults)
        let run: MonitorDeliveryRemoteRun<String> = model.remoteRun(
            request: request(project: nil, reupload: true), identity: { $0 },
            admission: .init { true })
        #expect(run.reupload)
        #expect(run.history?.wasUploaded("clip-a") == false)
        run.history?.recordUploaded("clip-a")
        #expect(defaults.string(forKey: namespace.historyKey) == "clip-a")
        let reopened = FrameioAccountModel(namespace: namespace, configuration: nil, defaults: defaults)
            .remoteRun(
                request: request(project: nil, reupload: false), identity: { (record: String) in record },
                admission: .init { true })
        #expect(reopened.history?.wasUploaded("clip-a") == true)
        #expect(!reopened.reupload)
    }

    @Test func unconfiguredBuildIsNeverConnected() {
        let model = FrameioAccountModel(namespace: namespace, configuration: nil, defaults: defaults())
        #expect(!model.isConfigured && !model.isConnected)
        #expect(throws: FrameioError.self) { try model.client() }
    }
}
#endif
