#if os(iOS)
import Metal
import OpenCineAppKitApple
import XCTest

/// Moved from both apps' LiveHDRDisplayTests (each app now holds one `LiveHDRDisplay.app`).
@MainActor
final class LiveHDRDisplayTests: XCTestCase {
    private var display = LiveHDRDisplay()

    override func tearDown() {
        display.setScreenCaptured(false)
        display.setChromeActive(false)
        display.setEnabled(false)
        super.tearDown()
    }

    func testDisplayGainIsRequestedHeadroomCappedByThePanel() {
        XCTAssertEqual(LiveHDRDisplay.requestedHeadroom, 3, accuracy: 0.001)
        let cases: [(name: String, enabled: Bool, potential: CGFloat, expected: Float)] = [
            ("disabled on an HDR panel", false, 8, 1),
            ("disabled on an SDR panel", false, 1, 1),
            ("panel has room", true, 8, Float(LiveHDRDisplay.requestedHeadroom)),
            ("panel potential caps the gain", true, 1.4, 1.4),
            ("SDR panel", true, 1, 1),
            ("NaN potential falls back to one", true, .nan, 1),
            ("infinite potential falls back to one", true, .infinity, 1),
        ]
        for c in cases {
            XCTAssertEqual(
                LiveHDRDisplay.displayGain(enabled: c.enabled, potentialHeadroom: c.potential),
                c.expected, accuracy: 0.001, c.name)
        }
    }

    func testDrawableFormatIsFloatOnlyWhileEnabled() {
        XCTAssertEqual(LiveHDRDisplay.drawablePixelFormat(enabled: false), .bgra8Unorm)
        XCTAssertEqual(LiveHDRDisplay.drawablePixelFormat(enabled: true), .rgba16Float)
        XCTAssertEqual(LiveHDRDisplay.bakePixelFormat, .bgra8Unorm)
    }

    func testChromeGainFollowsThePreference() {
        display.setScreenCaptured(false)
        display.setEnabled(true)
        XCTAssertEqual(display.chromeGain, display.presentGain)
        display.setEnabled(false)
        XCTAssertEqual(display.chromeGain, 1)
    }

    func testScreenCaptureDisablesEffectiveHDR() {
        XCTAssertTrue(LiveHDRDisplay.isEffective(preferred: true, screenCaptured: false))
        XCTAssertFalse(LiveHDRDisplay.isEffective(preferred: true, screenCaptured: true))
        XCTAssertFalse(LiveHDRDisplay.isEffective(preferred: false, screenCaptured: false))
        display.setScreenCaptured(false)
        display.setEnabled(true)
        XCTAssertTrue(display.isEnabled)
        display.setScreenCaptured(true)
        XCTAssertFalse(display.isEnabled)
        XCTAssertEqual(display.presentGain, 1)
        display.setScreenCaptured(false)
        XCTAssertTrue(display.isEnabled)
    }
}
#endif
