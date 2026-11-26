import XCTest

@testable import Insta360Protocol

/// Which Insta360 bodies the Luna integration connects to, what each is called and what its
/// lenses can do. Kotlin twin: `LunaModelTest`, same method names.
final class LunaModelTests: XCTestCase {
    func testTheLunaUltraAndLunaProAreSupported() {
        XCTAssertEqual(LunaModel.identify("Insta360 Luna Ultra"), .ultra)
        XCTAssertEqual(LunaModel.identify("Insta360 Luna Pro"), .pro)
        // The Pro's string is unconfirmed on hardware: case, spacing and the brand prefix do not matter.
        XCTAssertEqual(LunaModel.identify("  insta360  LUNA pro "), .pro)
        XCTAssertEqual(LunaModel.identify("Luna Pro"), .pro)
        XCTAssertEqual(LunaModel.supported, [.ultra, .pro])
    }

    func testOtherCamerasAndUnknownLunaVariantsAreRefused() {
        for reported in ["Insta360 ONE RS", "Insta360 X4", "", "Insta360", "Insta360 Luna", "Insta360 Luna Max", "Insta360 Luna Ultra 2"] {
            XCTAssertNil(LunaModel.identify(reported), reported)
        }
        XCTAssertFalse(LunaModel.isLunaFamily("Insta360 ONE RS"))
        XCTAssertFalse(LunaModel.isLunaFamily("Insta360 Lunar"))
        XCTAssertTrue(LunaModel.isLunaFamily("Insta360 Luna Max"))
    }

    func testTheRefusalNamesTheCameraAndTheSupportedBodies() {
        XCTAssertEqual(
            LunaModel.unsupportedMessage(reported: "Insta360 ONE RS", appName: "OpenInstaCine"),
            "This camera is Insta360 ONE RS. OpenInstaCine currently supports the Insta360 Luna Ultra and Luna Pro.")
        XCTAssertEqual(
            LunaModel.unsupportedMessage(reported: "Insta360  Luna Max", appName: "OpenInstaCine"),
            "This camera is Insta360 Luna Max, a Luna model OpenInstaCine does not support yet. "
                + "OpenInstaCine currently supports the Insta360 Luna Ultra and Luna Pro.")
        XCTAssertEqual(
            LunaModel.unsupportedMessage(reported: " ", appName: "This app"),
            "This camera did not report its model. This app currently supports the Insta360 Luna Ultra and Luna Pro.")
    }

    func testEachBodyHasItsNameAndLenses() {
        XCTAssertEqual(LunaModel.ultra.name, "Luna Ultra")
        XCTAssertEqual(LunaModel.pro.name, "Luna Pro")
        XCTAssertEqual(LunaModel.familyName, "Luna")
        // Ultra: unchanged from before the Pro (presets of fw 1.1.15, 15x, tele at 3x).
        XCTAssertTrue(LunaModel.ultra.hasTelephoto)
        XCTAssertEqual(LunaModel.ultra.zoomPresets, [1, 2, 3, 6, 15])
        XCTAssertEqual(LunaModel.ultra.maximumZoom, LunaProtocol.maximumZoomScale)
        XCTAssertEqual(LunaModel.ultra.opticalZoomStops, [1, 3])
        XCTAssertTrue(LunaModel.ultra.hardwareQualified)
        // Pro: one main camera, so no 3x stop and nothing past its 4x.
        XCTAssertFalse(LunaModel.pro.hasTelephoto)
        XCTAssertEqual(LunaModel.pro.zoomPresets, [1, 2, 4])
        XCTAssertEqual(LunaModel.pro.maximumZoom, 4)
        XCTAssertEqual(LunaModel.pro.opticalZoomStops, [1])
        XCTAssertFalse(LunaModel.pro.zoomPresets.contains(3))
        XCTAssertFalse(LunaModel.pro.hardwareQualified, "untested until a Luna Pro connects")
        for model in LunaModel.supported {
            XCTAssertEqual(model.zoomPresets.first, 1)
            XCTAssertEqual(model.zoomPresets.last, model.maximumZoom)
        }
    }
}
