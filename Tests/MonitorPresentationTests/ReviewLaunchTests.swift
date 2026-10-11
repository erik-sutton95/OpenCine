import MonitorPresentation
import Testing

@Suite("Review launch contract")
struct ReviewLaunchTests {
    @Test func everyFieldRoundTripsThroughTheLaunchEnvironment() {
        let launches = [
            ReviewLaunch(screen: .live),
            ReviewLaunch(
                screen: .playback, state: "connecting", layout: .list, mediaCount: 3, source: .camera,
                connected: true, settingsTab: .display, commonControls: false, meteredEV: -2.0 / 3),
        ] + ReviewLaunch.Screen.allCases.map { ReviewLaunch(screen: $0) }
        for launch in launches {
            #expect(ReviewLaunch(environment: launch.environment) == launch)
        }
    }

    @Test func theWireUsesTheExistingReviewNames() {
        let environment = ReviewLaunch(
            screen: .chromeEdit, state: "empty", layout: .list, mediaCount: 12, source: .camera,
            connected: true, settingsTab: .storage, commonControls: false, meteredEV: -0.5
        ).environment
        #expect(
            environment == [
                "OPV_UI_REVIEW_SCREEN": "chrome-edit", "OPV_UI_REVIEW_STATE": "empty",
                "OPV_UI_REVIEW_MEDIA_LAYOUT": "list", "OPV_UI_REVIEW_MEDIA_COUNT": "12",
                "OPV_UI_REVIEW_MEDIA_SOURCE": "camera", "OPV_UI_REVIEW_CONNECTED": "1",
                "OPV_UI_REVIEW_SETTINGS_TAB": "Storage", "OPV_UI_REVIEW_COMMON_CONTROLS": "0",
                "OPV_UI_REVIEW_METERED_EV": "-0.5",
            ])
    }

    @Test func absentValuesTakeTheDefaults() {
        #expect(ReviewLaunch(environment: ["OPV_UI_REVIEW_SCREEN": "media"]) == ReviewLaunch(screen: .media))
        #expect(ReviewLaunch(environment: [:]) == nil)
    }

    @Test func malformedValuesStageNothing() {
        for (key, value) in [
            ("OPV_UI_REVIEW_SCREEN", "media-fixture"), ("OPV_UI_REVIEW_SCREEN", ""),
            ("OPV_UI_REVIEW_MEDIA_LAYOUT", "tiles"), ("OPV_UI_REVIEW_MEDIA_COUNT", "0"),
            ("OPV_UI_REVIEW_MEDIA_COUNT", "many"), ("OPV_UI_REVIEW_MEDIA_SOURCE", "cloud"),
            ("OPV_UI_REVIEW_CONNECTED", "yes"), ("OPV_UI_REVIEW_COMMON_CONTROLS", "true"),
            ("OPV_UI_REVIEW_SETTINGS_TAB", "display"), ("OPV_UI_REVIEW_METERED_EV", "14 thirds"),
            ("OPV_UI_REVIEW_METERED_EV", "nan"),
        ] {
            var environment = ReviewLaunch(screen: .media).environment
            environment[key] = value
            #expect(ReviewLaunch(environment: environment) == nil, "\(key)=\(value)")
        }
    }
}
