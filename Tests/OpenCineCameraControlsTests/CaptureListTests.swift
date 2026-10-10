#if os(iOS)
    import MonitorPresentation
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import XCTest

    @testable import OpenCineCameraControls

    final class CaptureListTests: XCTestCase {
        private static let range100Body = CameraModel(name: "100 ISO body",
            captureProfile: CameraCaptureProfile(isoAutoRangeFloor: 100))

        func testFocusDrumPreservesUnknownStateAndEveryExistingTrackingMode() {
            var status = CameraStatus()
            XCTAssertNil(CaptureLists.focusOption(from: status))
            status.focusMode = .single
            status.focusTrack = .registeredPriority
            XCTAssertEqual(CaptureLists.focusOption(from: status), .single)
            status.focusMode = .continuous
            for option in FocusOption.allCases where option != .single {
                status.focusTrack = option.track
                XCTAssertEqual(CaptureLists.focusOption(from: status), option)
                XCTAssertFalse(CaptureLists.focusHelp(option).isEmpty)
            }
            XCTAssertEqual(
                FocusOption.allCases.map(\.chip), ["AF-S", "AF-C", "Showcase", "Lock", "Priority"])
        }

        func testIsoWheelUsesCamcapAndStarsBaseForTransfer() {
            var dlog2 = CameraStatus()
            dlog2.colorMode = .dLog2
            dlog2.availableIsoIndices = Self.isoDLog2
            XCTAssertEqual(
                CaptureLists.isoDrumLabels(from: dlog2),
                ["100", "200", "400", "800", "1600", "3200"])
            XCTAssertEqual(
                CaptureLists.isoDrumLabels(from: dlog2), dlog2.availableIsoIndices.map(\.label))
            XCTAssertEqual(CaptureLists.isoMarkedLabels(from: dlog2), ["1600"])
            XCTAssertEqual(dlog2.monitorTransfer, .dlog2)

            var dlog = CameraStatus()
            dlog.colorMode = .dLog
            dlog.availableIsoIndices = Self.isoDLog
            XCTAssertEqual(
                CaptureLists.isoDrumLabels(from: dlog),
                dlog.availableIsoIndices.filter { $0 != .auto }.map(\.label))
            XCTAssertEqual(CaptureLists.isoMarkedLabels(from: dlog), ["400"])
            XCTAssertFalse(CaptureLists.isoMarkedLabels(from: dlog).contains("1600"))

            var rec709 = CameraStatus()
            rec709.colorMode = .normal
            rec709.availableIsoIndices = dlog2.availableIsoIndices
            XCTAssertTrue(CaptureLists.isoMarkedLabels(from: rec709).isEmpty)
            XCTAssertEqual(
                CaptureLists.isoDrumLabels(from: rec709), CaptureLists.isoDrumLabels(from: dlog2))
        }

        func testPhotoDoesNotInheritVideoIsoStars() {
            var status = CameraStatus()
            status.colorMode = .dLog2
            status.shootingMode = Int(ShootingMode.video.rawValue)
            XCTAssertEqual(CaptureLists.isoMarkedLabels(from: status), ["1600"])
            status.shootingMode = Int(ShootingMode.photo.rawValue)
            XCTAssertTrue(CaptureLists.isoMarkedLabels(from: status).isEmpty)
            status.shootingMode = Int(ShootingMode.livePhoto.rawValue)
            XCTAssertTrue(status.isPhoto)
            XCTAssertTrue(CaptureLists.isoMarkedLabels(from: status).isEmpty)
            XCTAssertEqual(CaptureLists.recordingCategories(isPhoto: true), [.mode])
            XCTAssertEqual(
                CaptureLists.recordingCategories(isPhoto: false), [.resolution, .color, .mode])
            XCTAssertFalse(
                CaptureLists.operatorShootingModes().contains(.livePhoto),
                "Live Photo is camera-reported stills, not an unqualified MODE SET")
            var live = CameraStatus()
            live.shootingMode = Int(ShootingMode.livePhoto.rawValue)
            XCTAssertEqual(
                CaptureLists.operatorShootingModes(from: live).last { $0 == .livePhoto },
                .livePhoto)
            var leftover = CameraStatus()
            leftover.colorMode = .dLog2
            leftover.shootingMode = Int(ShootingMode.photo.rawValue)
            leftover.availableIsoIndices = [.auto, .iso100, .iso200, .iso400]
            leftover.isoLimit = .max1600
            XCTAssertTrue(CaptureLists.offersIsoAuto(from: leftover))
            XCTAssertEqual(
                CaptureLists.isoAutoLabels(from: leftover, model: Self.range100Body).first, "100–200",
                "Photo Auto ISO must not inherit leftover D-Log2")
            XCTAssertEqual(CaptureLists.isoAutoLabel(from: leftover, model: Self.range100Body), "100–1600")
            leftover.availableIsoIndices = []
            leftover.isoIndex = .iso400
            XCTAssertTrue(
                CaptureLists.offersIsoAuto(from: leftover),
                "Empty Photo camcap keeps Normal Auto fallback, including Pocket 3")
            XCTAssertEqual(CaptureLists.isoIndices(from: leftover), ColorMode.normal.isoIndices)
            leftover.colorMode = .dLog
            leftover.availableIsoIndices = [.auto, .iso400]
            XCTAssertEqual(
                CaptureLists.isoLimit(from: "100–800", status: leftover, model: Self.range100Body), .max800,
                "Photo ISO-limit labels ignore leftover D-Log 400-base")
        }

        func testIsoStarFollowsStatusTransferNotTeleHopGuess() {
            var status = CameraStatus()
            status.colorMode = .dLog2
            XCTAssertEqual(CaptureLists.isoMarkedLabels(from: status), ["1600"])
            status.colorMode = .dLog
            XCTAssertEqual(
                CaptureLists.isoMarkedLabels(from: status), ["400"],
                "star follows status.monitorTransfer after the body reports D-Log")
            XCTAssertEqual(CamFov.colorMode(forZoom: 3, current: .dLog2), .dLog)
            status.colorMode = .dLog2
            XCTAssertEqual(
                CaptureLists.isoMarkedLabels(from: status), ["1600"],
                "zoom tele hop guess must not flip the star while status is still D-Log2")
        }

        func testDLog2HasNoIsoAuto() {
            var status = CameraStatus()
            status.colorMode = .dLog2
            XCTAssertFalse(ColorMode.dLog2.offersIsoAuto)
            XCTAssertTrue(ColorMode.dLog2.isoAutoLimits.isEmpty)
            XCTAssertTrue(ColorMode.dLog2.isoAutoLabels.isEmpty)
            XCTAssertFalse(ColorMode.dLog2.isoIndices.contains(.auto))
            XCTAssertFalse(CaptureLists.offersIsoAuto(from: status))
            XCTAssertTrue(CaptureLists.isoAutoLabels(from: status).isEmpty)
        }

        func testDLogIsoAutoRanges() {
            var status = CameraStatus()
            status.colorMode = .dLog
            XCTAssertEqual(
                CaptureLists.isoAutoLabels(from: status),
                ["400–800", "400–1600", "400–3200", "400–6400"])
            XCTAssertEqual(ColorMode.dLog.isoAutoLimits.map(\.rawValue), [0x04, 0x05, 0x06, 0x07])
            XCTAssertEqual(CaptureLists.isoLimit(from: "400–1600", status: status), .max1600)
            XCTAssertTrue(CaptureLists.offersIsoAuto(from: status))
        }

        func testNormalAndHdrIsoAutoRanges() {
            let expected = [
                "100–200", "100–400", "100–800", "100–1600",
                "100–3200", "100–6400", "100–12800", "100–25600",
            ]
            var normal = CameraStatus()
            normal.colorMode = .normal
            var hdr = CameraStatus()
            hdr.colorMode = .hdr
            XCTAssertEqual(CaptureLists.isoAutoLabels(from: normal, model: Self.range100Body), expected)
            XCTAssertEqual(CaptureLists.isoAutoLabels(from: hdr, model: Self.range100Body), expected)
            XCTAssertEqual(CaptureLists.isoLimit(from: "100–800", status: normal, model: Self.range100Body), .max800)
            XCTAssertEqual(CaptureLists.isoLimit(from: "100–25600", status: hdr, model: Self.range100Body), .max25600)
            XCTAssertEqual(IsoLimit.max200.rawValue, 0x02)
            XCTAssertEqual(IsoLimit.max400.rawValue, 0x03)
            XCTAssertEqual(IsoLimit.max3200.rawValue, 0x06)
            XCTAssertEqual(IsoLimit.max12800.rawValue, 0x08)
        }

        func testPocket3IsoAutoRangesStartAt50() {
            let p3 = CameraModel(name: "50 ISO body", captureProfile: CameraCaptureProfile(isoAutoRangeFloor: 50))
            let expected = [
                "50–200", "50–400", "50–800", "50–1600",
                "50–3200", "50–6400", "50–12800", "50–25600",
            ]
            var normal = CameraStatus()
            normal.colorMode = .normal
            XCTAssertEqual(CaptureLists.isoAutoLabels(from: normal, model: p3), expected)
            XCTAssertEqual(
                CaptureLists.isoLimit(from: "50–400", status: normal, model: p3), .max400)
            var live = CameraStatus()
            live.colorMode = .normal
            live.isoLimit = .max400
            XCTAssertEqual(CaptureLists.isoAutoLabel(from: live, model: p3), "50–400")
            let p4 = CameraModel(name: "50 ISO body", captureProfile: CameraCaptureProfile(isoAutoRangeFloor: 50))
            XCTAssertEqual(CaptureLists.isoAutoLabels(from: normal, model: p4).first, "50–200")
            let p4p = CameraModel(name: "100 ISO body", captureProfile: CameraCaptureProfile(isoAutoRangeFloor: 100))
            XCTAssertEqual(CaptureLists.isoAutoLabels(from: normal, model: p4p).first, "100–200")
        }

        func testShutterAngleLadderIsCalculatedNotCaptured() {
            XCTAssertEqual(ShutterAngle.labels.first, "5.6°")
            XCTAssertEqual(ShutterAngle.labels.last, "360°")
            XCTAssertEqual(ShutterAngle.denom(degrees: 180, fps: 24), 48)
            XCTAssertEqual(ShutterAngle.denom(degrees: 180, fps: 24, available: [25, 50, 100]), 50)
            XCTAssertEqual(ShutterAngle.nearestLabel(denom: 48, fps: 24), "180°")
        }

        /// The camera's D-Log2 ISO list (`camcap_iso` indices `03…08`; decode tested in OpenCine).
        private static let isoDLog2: [IsoIndex] = [
            .iso100, .iso200, .iso400, .iso800, .iso1600, .iso3200,
        ]
        /// The camera's D-Log ISO list (`camcap_iso` indices `00 05…09`).
        private static let isoDLog: [IsoIndex] = [
            .auto, .iso400, .iso800, .iso1600, .iso3200, .iso6400,
        ]
    }
#endif
