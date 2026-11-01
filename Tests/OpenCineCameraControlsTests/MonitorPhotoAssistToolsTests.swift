#if os(iOS)
import MonitorPresentation
import OpenCineCameraControls
import Testing

/// What a still offers in the shared view assist bar (owner hardware pass 2026-10-31): the
/// playback bar's tools that read or draw on a still, in the playback order. Kotlin twin:
/// `MonitorAssistTool.photoToolbarCases`.
@Suite struct MonitorPhotoAssistToolsTests {
    @Test func aStillOffersThePlaybackBarsPictureToolsInItsOrder() {
        let still = MonitorAssistSelection.photoToolbarCases
        for tool in [MonitorAssistSelection.desqueeze, .mirror, .guides, .grid, .crosshair,
            .peaking, .falseColor, .zebra, .waveform, .parade, .histogram, .vectorscope, .trafficLights] {
            #expect(still.contains(tool), "\(tool.rawValue)")
        }
        #expect(still == MonitorAssistSelection.playbackToolbarCases.filter(still.contains))
    }

    @Test func aStillNeverOffersALookCubeSoundOrCameraReadings() {
        let still = Set(MonitorAssistSelection.photoToolbarCases)
        for tool in [MonitorAssistSelection.lut, .audioMeters, .ndMeter, .evMeter, .level, .magnification] {
            #expect(!still.contains(tool), "\(tool.rawValue)")
        }
    }
}
#endif
