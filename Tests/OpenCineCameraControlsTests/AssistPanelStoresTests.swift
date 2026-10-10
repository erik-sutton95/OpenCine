#if os(iOS)
    import Foundation
    import OpenCineAppKit
    import Testing

    @testable import OpenCineCameraControls

    /// The panel settings keep each app's saved keys: a renamed key would lose every operator's
    /// scope sizes and places on upgrade.
    @MainActor
    @Suite struct AssistPanelStoresTests {
        @Test func eachStoreSavesUnderTheAppNamespace() throws {
            let name = "AssistPanelStoresTests.\(UUID().uuidString)"
            let storage = try #require(UserDefaults(suiteName: name))
            defer { storage.removePersistentDomain(forName: name) }
            let stores = AssistPanelStores(storage: storage, namespace: "App")
            stores.waveform.persist()
            stores.parade.persist()
            stores.vectorscope.persist()
            stores.histogram.persist()
            stores.audio.persist()
            stores.nd.persist()
            stores.trafficLights.persist()
            stores.zebraUnit = .native
            stores.reference.setCenter(
                CGPoint(x: 10, y: 10), in: CGRect(x: 0, y: 0, width: 100, height: 100))
            let keys = Set(storage.dictionaryRepresentation().keys.filter { $0.hasPrefix("App.") })
            #expect(
                keys == [
                    "App.WaveformAssist.v1", "App.ParadeAssist.v1", "App.VectorscopeAssist.v1",
                    "App.HistogramAssist.v1", "App.Assist.audio.v1", "App.Assist.ndMeter.v1",
                    "App.Assist.trafficLights.v1", "App.Assist.falseColorReference.positions.v1",
                    "App.zebraUnit",
                ])
        }
    }
#endif
