import Foundation
import MonitorPresentation
import Testing

@testable import OpenCineAppKit

@MainActor
struct MonitorTeleprompterModelTests {
    @Test func legacyTextAndPreferencesMigrateWithoutDecodingOrAutoplay() throws {
        guard #available(macOS 14, *) else { return }
        let key = "teleprompter-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        defaults.set(
            "Keep **these words** exactly.\n\nSecond paragraph.", forKey: "teleprompter.script")
        defaults.set(54.0, forKey: "teleprompter.fontSize")
        defaults.set(28.0, forKey: "teleprompter.speed")
        defaults.set(true, forKey: "teleprompter.mirrored")
        let model = MonitorTeleprompterModel(defaults: defaults)
        #expect(model.script?.text == "Keep **these words** exactly.\n\nSecond paragraph.")
        #expect(model.script?.name == "Script" && model.script?.sourceURL == nil)
        #expect(model.fontSize == 54 && model.speed == 28 && model.mirrored)
        #expect(model.showsPreview && model.backgroundOpacity == 0.4)
        #expect(!model.playing && model.position == 0)
    }

    @Test func previewCancelAndFailurePreserveTheAcceptedOfflineScript() async throws {
        guard #available(macOS 14, *) else { return }
        let key = "teleprompter-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let model = MonitorTeleprompterModel(defaults: defaults)
        model.previewPaste("Original script")
        model.useCandidate()
        model.previewPaste("Replacement script")
        #expect(model.script?.text == "Original script")
        model.cancelImport()
        #expect(!model.updateText("Invalid\u{0}script"))
        #expect(model.candidate == nil)
        #expect(model.script?.text == "Original script")
        await model.load { throw TestFailure.unavailable }.value
        #expect(model.error != nil)
        #expect(model.script?.text == "Original script")
        #expect(MonitorTeleprompterModel(defaults: defaults).script?.text == "Original script")
    }

    @Test func latestImportOwnsThePreviewEvenWhenCancelledWorkReturnsLate() async throws {
        guard #available(macOS 14, *) else { return }
        let key = "teleprompter-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let model = MonitorTeleprompterModel(defaults: defaults)
        let gate = ImportGate()
        let first = model.load {
            await gate.wait()
            return TeleprompterScript(text: "Old", name: "Old")
        }
        let second = model.load { TeleprompterScript(text: "Current", name: "Current") }
        await second.value
        await gate.release()
        await first.value
        #expect(model.candidate?.text == "Current")
        #expect(model.script == nil)
        #expect(!model.loading)
    }

    @Test func reopeningPreservesTextSourceAndSettingsButNeverRestartsPlayback() async throws {
        guard #available(macOS 14, *) else { return }
        let key = "teleprompter-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let model = MonitorTeleprompterModel(defaults: defaults)
        let url = try #require(URL(string: "https://example.com/script.md"))
        let script = TeleprompterScript(
            text: "First paragraph.\n\nSecond paragraph: café.", name: "script.md", sourceURL: url)
        await model.load { script }.value
        model.useCandidate()
        model.fontSize = 54
        model.speed = 28
        model.mirrored = true
        model.backgroundOpacity = 0.65
        model.showsPreview = false
        model.position = 120
        model.playing = true
        model.requestEditor()
        #expect(!model.playing)
        #expect(model.position == 120)
        #expect(model.updateText(script.text))
        #expect(model.position == 120 && !model.playing)
        let restored = MonitorTeleprompterModel(defaults: defaults)
        #expect(restored.script == script)
        #expect(restored.fontSize == 54 && restored.speed == 28 && restored.mirrored)
        #expect(restored.backgroundOpacity == 0.65 && !restored.showsPreview)
        #expect(!restored.playing && restored.position == 0)
    }

    @Test(arguments: [10.0, 28.0, 100.0, 300.0])
    func savedSpeedRestoresAcrossTheFullSupportedRange(speed: Double) throws {
        guard #available(macOS 14, *) else { return }
        let key = "teleprompter-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let model = MonitorTeleprompterModel(defaults: defaults)
        model.speed = speed
        #expect(MonitorTeleprompterModel(defaults: defaults).speed == speed)
    }

    private enum TestFailure: LocalizedError {
        case unavailable
        var errorDescription: String? { "Unavailable" }
    }
    private actor ImportGate {
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            if released { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func release() {
            released = true
            waiter?.resume()
            waiter = nil
        }
    }
}
