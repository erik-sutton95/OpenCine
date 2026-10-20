import Foundation
import OpenCineMedia
import Testing

@testable import OpenCineCameraVocabulary

/// Values one camera reports and another never does: the I-Log curve, the Dolby Vision format,
/// ISO 160, the 8K/6K/3K sizes, a plain zoom factor, direct-path media and per-session labels.
/// A camera that never reports them sees exactly what it saw before they existed.
@Suite struct CameraCapabilityCasesTests {
    @Test func iso160StepsByValueOnlyWhenTheListHasIt() {
        let withThird = ColorMode.iLog.isoIndices
        #expect(IsoIndex.iso160.isoValue == 160)
        #expect(IsoIndex.stepped(from: .iso160, stops: 1, available: withThird) == .iso200)
        #expect(IsoIndex.stepped(from: .iso100, stops: 1, available: withThird) == .iso200, "160 is a start point only")
        #expect(IsoIndex.stepped(from: .iso200, stops: -1, available: withThird) == .iso100)
        // Without 160 the camera's own order stands, unsorted.
        let cameraOrder: [IsoIndex] = [.iso800, .iso100, .iso400]
        #expect(IsoIndex.stepped(from: .iso800, stops: 1, available: cameraOrder) == .iso100)
    }

    /// Product ruling 2026-10-16: the curve the curve-reading tools need is known only for a
    /// reported mode that names one. Dolby Vision and an unreported mode stay unknown.
    @Test func theKnownSourceCurveLeavesDolbyVisionAndAnUnreportedModeUnknown() {
        #expect(MonitorTransfer.known(nil) == nil)
        #expect(MonitorTransfer.known(.dolbyVision) == nil)
        for mode in ColorMode.allCases where mode != .dolbyVision {
            #expect(MonitorTransfer.known(mode) == MonitorTransfer(mode), "\(mode)")
        }
    }

    @Test func iLogAndDolbyVisionNameTheirCurveAndFormat() {
        #expect(MonitorTransfer(ColorMode.iLog) == .ilog)
        #expect(MonitorTransfer(ColorMode.dolbyVision) == .rec709)
        #expect(ColorMode.iLog.bindsAutoLUT)
        #expect(!ColorMode.dolbyVision.bindsAutoLUT)
        #expect(ColorMode(label: "I-Log") == .iLog)
        #expect(ColorMode(label: "Dolby Vision") == .dolbyVision)
        #expect(ColorMode.dolbyVision.isoIndices == ColorMode.iLog.isoIndices)

    }

    @Test func labelProfileRenamesPerSessionAndStandardKeepsTheVocabulary() {
        let profile = CameraLabelProfile(
            colorModeLabels: [.normal: "Standard"],
            media: MediaHTTP.Route(host: "192.168.42.1", addressing: .directPath))
        #expect(ColorMode.normal.label(in: profile) == "Standard")
        #expect(ColorMode(label: "Standard", in: profile) == .normal)
        #expect(ColorMode.normal.label(in: .standard) == "Normal")
        #expect(ColorMode(label: "Standard") == nil)
        #expect(CameraLabelProfile.standard.media == .cameraSoftAP)
    }

    @Test func plainZoomFactorAndLongerLensCeiling() {
        var status = CameraStatus()
        let hybrid = status.zoomFactor
        status.zoomFactorOverride = 2.5
        #expect(status.zoomFactor == 2.5)
        status.zoomFactorOverride = nil
        #expect(status.zoomFactor == hybrid)
        #expect(CamFov.displayLabel(factor: 15, ceiling: 15) == "15×")
        #expect(CamFov.displayLabel(factor: 12) == "12×")
    }

    /// II-105: a host stop past the DJI ceiling (Luna 15×) is still a pinch detent; the default
    /// 1/3/6/12 stops are unchanged.
    @Test func jumpStopBeyondTheDefaultCeilingIsADetent() {
        #expect(CamFov.isJumpStop(15, stops: [1, 2, 3, 6, 15]))
        #expect(!CamFov.isJumpStop(14.2, stops: [1, 2, 3, 6, 15]))
        #expect(CamFov.isJumpStop(12) && CamFov.isJumpStop(6))
    }

    @Test func directPathMediaAndSplitFilenameStamp() {
        let direct = MediaHTTP.Route(host: "192.168.42.1", addressing: .directPath)
        #expect(
            MediaHTTP.pathURL(storage: 1, path: "DCIM/Camera01/VID_20260916_123456_00_001.mp4", route: direct)?
                .absoluteString == "http://192.168.42.1/DCIM/Camera01/VID_20260916_123456_00_001.mp4")
        #expect(
            MediaHTTP.pathURL(storage: 1, path: "/DCIM/a.mp4")
                == MediaHTTP.pathURL(storage: 1, path: "/DCIM/a.mp4", route: .cameraSoftAP))
        let clip = MediaFile(path: "/DCIM/Camera01/VID_20260916_123456_00_001.mp4", thumbPath: "")
        #expect(clip.filenameTimestamp == "20260916123456")
        #expect(MediaFile(path: "/DCIM/DJI_20260814125250_0034_D.MP4", thumbPath: "").filenameTimestamp == "20260814125250")
        #expect(MediaHTTP.derivedProxyExtension(filename: clip.filename) == "lrv")
        #expect(MediaHTTP.derivedProxyExtension(filename: "VID_20260916_123456_00_001.insv") == nil)
        #expect(MediaHTTP.derivedProxyExtension(filename: "DJI_20260814125250_0034_D.MP4") == "LRF")
    }
}
