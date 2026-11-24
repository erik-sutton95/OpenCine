import Foundation
import OpenCineAppKit
import Testing

/// The one network a computer's cameras join: asked for once, reused while its password is kept.
@Suite struct CameraNetworkMemoryTests {
    @Test func firstPairingAsksAndSuggestsTheMacNetwork() {
        #expect(
            CameraNetworkMemory.step(saved: nil, hasPassword: { _ in false }, currentNetwork: "Studio")
                == .ask(suggested: "Studio"))
        #expect(CameraNetworkMemory.step(saved: nil, hasPassword: { _ in true }, currentNetwork: nil) == .ask(suggested: nil))
    }

    @Test func savedNetworkWithPasswordIsReused() {
        #expect(
            CameraNetworkMemory.step(saved: .init(network: "Studio"), hasPassword: { $0 == "Studio" }, currentNetwork: "Other")
                == .reuse(network: "Studio"))
    }

    @Test func missingPasswordAsksAgain() {
        #expect(
            CameraNetworkMemory.step(saved: .init(network: "Studio"), hasPassword: { _ in false }, currentNetwork: nil)
                == .ask(suggested: "Studio"))
    }

    @Test func changeAppliesToTheNextPairing() throws {
        let suite = "CameraNetworkMemoryTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CameraNetworkStore(defaults: defaults, key: "cameraNetwork")
        #expect(store.load() == nil)
        store.save(.init(network: "Studio"))
        store.save(.init(network: "Venue"))
        #expect(store.load() == .init(network: "Venue"))
        #expect(CameraNetworkStore(defaults: defaults, key: "cameraNetwork").load() == .init(network: "Venue"))
        #expect(
            CameraNetworkMemory.step(saved: store.load(), hasPassword: { _ in true }, currentNetwork: "Studio")
                == .reuse(network: "Venue"))
    }
}
