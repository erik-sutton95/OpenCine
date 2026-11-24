#if os(iOS)
import Foundation
import OpenCineAppKit
import OpenCineAppKitApple
import Testing

@Suite @MainActor struct MonitorVoicePreferencesTests {
    @Test func togglesPersistIndependently() throws {
        let suite = "voice.preferences.\(UUID().uuidString)"
        let storage = try #require(UserDefaults(suiteName: suite))
        defer { storage.removePersistentDomain(forName: suite) }
        let preferences = MonitorVoicePreferences(storage: storage)
        #expect(preferences.allows(.start))
        #expect(preferences.allows(.stop))
        #expect(preferences.allows(.preset(1)))
        preferences.setEnabled(false, for: .stop)
        preferences.setEnabled(false, for: .preset)

        let restored = MonitorVoicePreferences(storage: storage)
        #expect(restored.allows(.start))
        #expect(!restored.allows(.stop))
        #expect(!restored.allows(.preset(1)))
    }

    @Test func ignoresRemovedActionsWhileKeepingExistingChoices() throws {
        let suite = "voice.legacy-options.\(UUID().uuidString)"
        let storage = try #require(UserDefaults(suiteName: suite))
        defer { storage.removePersistentDomain(forName: suite) }
        storage.set(["stop": false, "lens": true, "frameRate": true, "iso": true], forKey: "monitor.voice.actions")
        let preferences = MonitorVoicePreferences(storage: storage)
        #expect(preferences.availableActions(supportsLens: false) == [.start, .stop, .preset])
        #expect(preferences.availableActions(supportsLens: true) == [.start, .stop, .preset, .lens])
        #expect(!preferences.allows(.stop))
        #expect(preferences.allows(.switchLens, supportsLens: true))
        preferences.setEnabled(false, for: .start)
        #expect(storage.dictionary(forKey: "monitor.voice.actions") as? [String: Bool] ==
            ["start": false, "stop": false, "lens": true])
    }

    @Test func lensRequiresBothCapabilityAndOptIn() throws {
        let suite = "voice.lens.\(UUID().uuidString)"
        let storage = try #require(UserDefaults(suiteName: suite))
        defer { storage.removePersistentDomain(forName: suite) }
        let preferences = MonitorVoicePreferences(storage: storage)
        #expect(!preferences.availableActions(supportsLens: false).contains(.lens))
        #expect(preferences.availableActions(supportsLens: true).contains(.lens))
        #expect(!preferences.allows(.switchLens, supportsLens: true))

        preferences.setEnabled(true, for: .lens)
        #expect(!preferences.allows(.switchLens))
        #expect(preferences.allows(.switchLens, supportsLens: true))
    }
}
#endif
