import MonitorPresentation
import Testing

/// A camera's own assist entries are typed declarations on the shared list; the standard
/// declaration leaves every other app's list as it was.
@Suite struct MonitorAssistCapabilitiesTests {
    @Test func theStandardDeclarationKeepsTheSharedList() {
        let standard = MonitorAssistCapabilities.standard
        #expect(standard.photographyOnly == [.instantReview])
        #expect(standard.levelStyles.isEmpty && !standard.hasLevelStyle)
        #expect(standard.unavailable.isEmpty)
        let cinema = MonitorAssistSelection.allCases.filter { standard.offers($0, photography: false) }
        #expect(cinema == MonitorAssistTool.allCases.map(MonitorAssistSelection.init))
        #expect(standard.offers(.instantReview, photography: true))
        #expect(!standard.offers(.magnification, photography: true))
    }

    @Test func aCameraDeclaresPhotographyOnlyToolsLevelStylesAndMissingSources() {
        let camera = MonitorAssistCapabilities(
            photographyOnly: [.instantReview, .evMeter], levelStyles: [.horizon, .gauge],
            unavailable: [.ndMeter])
        #expect(!camera.offers(.evMeter, photography: false))
        #expect(camera.offers(.evMeter, photography: true))
        #expect(!camera.offers(.ndMeter, photography: true))
        #expect(camera.hasLevelStyle)
        #expect(camera.levelStyles.map(\.title) == ["Horizon", "Gauge"])
        #expect(MonitorLevelStyle(rawValue: "Horizon") == .horizon)
    }
}
