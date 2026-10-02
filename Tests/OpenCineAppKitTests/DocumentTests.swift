import Foundation
import OpenCineAppKit
import OpenCineCore
import Testing

/// The stored document format, shared byte for byte with Kotlin (`DocumentTest`).
@MainActor
@Suite struct Document {
    @Test func theDocumentFormatIsShared() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/saved-cameras/document-v1.json")
        let fixture = try Data(contentsOf: url)
        let defaults = Defaults(["document": fixture])
        let store = SavedCamerasStore(document: defaults.at("document"))
        store.load()
        #expect(defaults.writes.isEmpty)

        let a = try #require(store.cameras.first)
        #expect(a.device == .durable("SN-1", integration: IntegrationID("test.cameras")))
        #expect(a.name == "A cam" && a.extras == ["modelId": "34"])
        #expect(milliseconds(a.lastConnected) == 1_759_307_200_250)
        #expect(a.routes.map(\.kind) == [.cameraAccessPoint, .infrastructureNetwork])
        #expect(a.preferredRoute == a.routes[1].id && a.routes[1].title == "Studio")
        #expect(a.routes[1].extras == ["band": "5"] && milliseconds(a.routes[1].lastConnected) == 1_759_307_200_250)
        #expect(store.cameras[1].routes.map(\.kind) == [.usb] && store.cameras[1].name == nil)

        store.save(store.cameras)
        #expect(defaults.values["document"] == fixture)
    }
}
