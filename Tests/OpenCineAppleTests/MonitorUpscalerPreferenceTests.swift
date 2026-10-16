#if canImport(Metal)
    import Foundation
    import Observation
    import OpenCineApple
    import XCTest
    import os

    @available(macOS 14.0, *)
    final class MonitorUpscalerPreferenceTests: XCTestCase {
        private var suite: String!
        private var defaults: UserDefaults!
        private let key = "OpenTestCine.feedUpscaler"

        override func setUp() {
            super.setUp()
            suite = "MonitorUpscalerPreferenceTests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)
        }

        override func tearDown() {
            defaults.removePersistentDomain(forName: suite)
            super.tearDown()
        }

        private func make(
            supported: @escaping (MonitorUpscaler?) -> MonitorUpscaler = { $0 ?? .lanczos },
            onChange: @escaping @Sendable (MonitorUpscaler) -> Void = { _ in }
        ) -> MonitorUpscalerPreference {
            MonitorUpscalerPreference(
                storageKey: key, defaults: defaults, supported: supported, onChange: onChange)
        }

        func testNothingStoredSeedsTheDeviceDefault() {
            let preference = make(supported: { $0 ?? .spatial })
            XCTAssertEqual(preference.upscaler, .spatial)
            XCTAssertNil(defaults.string(forKey: key), "An untouched launch persists nothing")
        }

        func testStoredRawValueIsRestoredUnderTheNamespacedKey() {
            defaults.set("Off", forKey: key)
            defaults.set("AI", forKey: "OpenOtherCine.feedUpscaler")
            XCTAssertEqual(make().upscaler, .off)
        }

        func testLegacyTitlesMigrateToTodaysRawValues() {
            for (legacy, expected) in [
                ("Lanczos", MonitorUpscaler.lanczos), ("MetalFX", .spatial),
                ("Super Res", .superResolution),
            ] {
                defaults.set(legacy, forKey: key)
                XCTAssertEqual(make().upscaler, expected, legacy)
                XCTAssertEqual(defaults.string(forKey: key), expected.rawValue, legacy)
            }
        }

        func testUnknownStoredValueFallsBackWithoutRewriting() {
            defaults.set("Bicubic", forKey: key)
            XCTAssertEqual(make(supported: { $0 ?? .lanczos }).upscaler, .lanczos)
            XCTAssertEqual(defaults.string(forKey: key), "Bicubic")
        }

        func testUnsupportedStoredChoiceIsClampedToWhatTheDeviceRuns() {
            defaults.set("AI", forKey: key)
            let preference = make(supported: {
                $0 == .superResolution ? .lanczos : ($0 ?? .lanczos)
            })
            XCTAssertEqual(preference.upscaler, .lanczos)
        }

        func testSettingPersistsReportsAndSurvivesRelaunch() {
            let reported = OSAllocatedUnfairLock(initialState: [MonitorUpscaler]())
            let preference = make(onChange: { value in reported.withLock { $0.append(value) } })
            preference.upscaler = .off
            preference.upscaler = .spatial
            XCTAssertEqual(reported.withLock { $0 }, [.off, .spatial])
            XCTAssertEqual(defaults.string(forKey: key), "Quality")
            XCTAssertEqual(make().upscaler, .spatial)
        }

        func testRendererReadsTheLatestChoiceOffTheMainThread() async {
            let preference = make()
            preference.upscaler = .off
            let read = await Task.detached { preference.upscaler }.value
            XCTAssertEqual(read, .off)
        }

        func testChangesAreObservable() {
            let preference = make()
            let changed = OSAllocatedUnfairLock(initialState: false)
            withObservationTracking {
                _ = preference.upscaler
            } onChange: {
                changed.withLock { $0 = true }
            }
            preference.upscaler = .off
            XCTAssertTrue(changed.withLock { $0 })
        }

        func testSuperResolutionInputPreviewIsNotPersisted() {
            let preference = make()
            XCTAssertFalse(preference.presentsSuperResolutionInput)
            preference.presentsSuperResolutionInput = true
            XCTAssertTrue(preference.presentsSuperResolutionInput)
            XCTAssertFalse(make().presentsSuperResolutionInput)
        }
    }
#endif
