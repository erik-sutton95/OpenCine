#if os(iOS)
import Testing

@testable import OpenCineCameraControls

/// A2-33: one cache scope and Clear wording every app shares. The captured cache view owns the
/// texts, so no app passes or falls back to a last-camera claim like "the clip list is kept".
@MainActor
@Suite struct CacheScopeWordingTests {
    @Test func capturedCacheStatesEveryCameraScopeAndNoClipListClaim() {
        #expect(MonitorSettingsCapturedCache.scopeHelpText.contains("across all paired cameras"))
        #expect(MonitorSettingsCapturedCache.confirmationText.contains("for every camera"))
        #expect(!MonitorSettingsCapturedCache.confirmationText.contains("clip list"))
        #expect(!MonitorSettingsCapturedCache.scopeHelpText.contains("this phone"))
    }
}
#endif
