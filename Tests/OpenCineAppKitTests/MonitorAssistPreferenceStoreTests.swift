import Foundation
import MonitorPresentation
import OpenCineAppKit
import Testing

@MainActor
@Suite struct MonitorAssistPreferenceStoreTests {
    private func storage() throws -> (UserDefaults, String) {
        let domain = "opencine-assist-store-tests." + UUID().uuidString
        return (try #require(UserDefaults(suiteName: domain)), domain)
    }

    @Test func legacyScopeCodecsPreserveIdentifiersAndExplicitScale() throws {
        guard #available(macOS 14, *) else { return }
        let legacy = Data(#"{"mode":"Luma","brightness":150,"guides":{"clip":false,"crush":true,"middle":false},"scale":1,"storedCenter":{"xFraction":0.25,"yFraction":0.75}}"#.utf8)
        let value = try JSONDecoder().decode(MonitorWaveformOptions.self, from: legacy)
        #expect(value.mode == .luma && value.brightness == 150 && value.hasCustomScale)
        #expect(!value.guides.clip && value.guides.crush && !value.guides.middle)
        #expect(value.storedCenter == .init(xFraction: 0.25, yFraction: 0.75))
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        #expect(Set(encoded.keys) == ["mode", "brightness", "guides", "scale", "hasCustomScale", "storedCenter"])
        #expect(encoded["mode"] as? String == "Luma" && encoded["hasCustomScale"] as? Bool == true)
        #expect(try JSONDecoder().decode(MonitorParadeOptions.self, from: Data(#"{"mode":"YRGB","scale":0.8}"#.utf8)).mode == .yrgb)
        #expect(try JSONDecoder().decode(MonitorVectorscopeOptions.self, from: Data(#"{"zoom":"4x","scale":1.6}"#.utf8)).zoom == .x4)
        let fresh = try JSONDecoder().decode(MonitorWaveformOptions.self, from: JSONEncoder().encode(MonitorWaveformOptions.default))
        #expect(!fresh.hasCustomScale)
    }

    @Test func scopeOwnerKeepsCanceledAndRotatedPlacementsOutOfOtherStorage() throws {
        guard #available(macOS 14, *) else { return }
        let (defaults, domain) = try storage()
        defer { defaults.removePersistentDomain(forName: domain) }
        let first = MonitorScopePanelStore<MonitorWaveformOptions>(storage: defaults, key: "first")
        let other = MonitorScopePanelStore<MonitorWaveformOptions>(storage: defaults, key: "other")
        #expect(defaults.object(forKey: "first") == nil)
        #expect(first.presentationScale(width: 400, height: 800, tablet: false) == 0.6)
        first.beginDrag(center: .init(x: 210, y: 420), slot: .portrait)
        first.cancelDrag(slot: .portrait)
        first.endDrag(canvas: .init(x: 10, y: 20, width: 400, height: 800))
        #expect(defaults.object(forKey: "first") == nil)
        first.drag(to: .init(x: 210, y: 420), slot: .portrait)
        first.endDrag(canvas: .init(x: 10, y: 20, width: 400, height: 800))
        first.drag(to: .init(x: 610, y: 220), slot: .landscape)
        first.endDrag(canvas: .init(x: 10, y: 20, width: 800, height: 400))
        first.setScale(5)
        let restored = MonitorScopePanelStore<MonitorWaveformOptions>(storage: defaults, key: "first")
        #expect(restored.options.scale == 1.6 && restored.options.hasCustomScale)
        #expect(restored.options.storedCenterPortrait == .init(xFraction: 0.5, yFraction: 0.5))
        #expect(restored.options.storedCenter == .init(xFraction: 0.75, yFraction: 0.5))
        #expect(restored.sessionPosition == nil && restored.sessionPositionPortrait == nil)
        #expect(other.options == .default && defaults.object(forKey: "other") == nil)
    }

    @Test func audioAndReferenceOwnersPreserveTheirDifferentCenterSchemas() throws {
        guard #available(macOS 14, *) else { return }
        let (defaults, domain) = try storage()
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(Data(#"{"orientation":"Horizontal","showsDB":true,"landscapeCenter":{"x":0.25,"y":0.75}}"#.utf8), forKey: "audio")
        let audio = MonitorAudioPreferenceStore(storage: defaults, key: "audio")
        #expect(audio.options.orientation == .horizontal && audio.options.showsDB)
        audio.setCenter(.init(x: 210, y: 420), canvas: .init(x: 10, y: 20, width: 400, height: 800))
        let reloaded = MonitorAudioPreferenceStore(storage: defaults, key: "audio")
        #expect(reloaded.options.landscapeCenter == .init(x: 0.25, y: 0.75))
        #expect(reloaded.options.portraitCenter == .init(x: 0.5, y: 0.5))
        let reference = MonitorFalseColorReferencePositionStore(storage: defaults, key: "reference")
        reference.setCenter(.init(x: 210, y: 420), canvas: .init(x: 10, y: 20, width: 400, height: 800))
        let data = try #require(defaults.data(forKey: "reference"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: Double]])
        #expect(object == ["portrait": ["x": 0.5, "y": 0.5]])
        #expect(MonitorFalseColorReferencePositionStore(storage: defaults, key: "other").positions == .init())
    }

    @Test func meterOwnersReadLegacyNotationAndLoadCompensationIntoHistogram() throws {
        guard #available(macOS 14, *) else { return }
        let (defaults, domain) = try storage()
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(Data(#"{"scale":3,"position":{"xFraction":0.1,"yFraction":0.2}}"#.utf8), forKey: "nd")
        let nd = MonitorNDPreferenceStore(storage: defaults, key: "nd")
        #expect(nd.scale == 1.6 && nd.notation == .factor)
        #expect(nd.position == .init(xFraction: 0.1, yFraction: 0.2))
        let histogram = MonitorScopePanelStore<MonitorHistogramOptions>(storage: defaults, key: "histogram")
        defaults.set(Data(#"{"compensation":2,"scale":0.8,"positionPortrait":{"xFraction":0.2,"yFraction":0.8}}"#.utf8), forKey: "lights")
        let lights = MonitorTrafficLightsPreferenceStore(storage: defaults, key: "lights", histogram: histogram)
        #expect(lights.compensation.rawValue == 2 && histogram.options.crushClipCompensation == lights.compensation)
        #expect(lights.positionPortrait == .init(xFraction: 0.2, yFraction: 0.8))
        lights.persist()
        let encoded = try #require(defaults.data(forKey: "lights"))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == ["compensation", "scale", "positionPortrait"])
        #expect(object["compensation"] as? Int == 2)
    }
}
