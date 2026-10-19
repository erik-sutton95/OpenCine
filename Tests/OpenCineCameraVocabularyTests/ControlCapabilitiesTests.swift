import Foundation
import OpenCineCore
import OpenCineMotion
import Testing

@testable import OpenCineCameraVocabulary

/// The merge rules of the one control model (Kotlin twin: `ControlCapabilitiesTest`).
@Suite struct ControlCapabilitiesTests {
    static let gimbal = MotionCapabilities(
        axes: [.pan, .tilt], frame: .handle, bounds: MotionBounds(pan: -90...90, tilt: -45...45),
        maxRateDegPerSec: nil, feedbackMaxAge: .milliseconds(300), arrivalToleranceDeg: 0.5,
        pose: .supported)

    @Test func nothingKnownIsUnknownNeverFalse() {
        let controls = ControlCapabilities(snapshot: CapabilitySnapshot(), profile: nil)
        for family in ControlFamily.allCases {
            #expect(controls.status(family).support == .unknown, "\(family)")
        }
        #expect(controls.offered.isEmpty)
    }

    @Test func aDescriptorDecidesSupportAccessAndValues() {
        let domain = SettingDomain(choices: [.iso(.auto), .iso(.manual(800))])
        let snapshot = CapabilitySnapshot(descriptors: [
            SettingDescriptor(.iso, domain: domain),
            SettingDescriptor(.frameRate, access: .readOnly),
            SettingDescriptor(.shutter, access: .readOnly),
        ], unsupported: [.whiteBalanceTint])
        let controls = ControlCapabilities(snapshot: snapshot, profile: nil)
        #expect(controls.iso.isOffered)
        #expect(controls.iso.offer?.setting?.domain == domain)
        #expect(controls.shutter.status == ControlStatus(support: .supported, access: .readOnly))
        #expect(!controls.shutter.isOffered && controls.shutter.isShown, "read-only is a readout")
        #expect(controls.tint.support == .unsupported)
        #expect(controls.whiteBalance.support == .unknown)
        #expect(controls.recordingFormat.isOffered, "a frame-rate observation means a format to show")
    }

    @Test func profileFlagsAndDeclarationsFillWhatTheSnapshotLacks() {
        var profile = CameraCaptureProfile(supportsFocusMode: true, supportsTapFocus: false,
            supportsAperture: true, hasGimbal: false, supportsZoom: nil,
            zoom: CameraZoomProfile(stops: [1, 2]))
        profile.controls = [.ndFilter: .unsupported, .faceMetering: .supported, .shutter: .supported]
        let snapshot = CapabilitySnapshot(
            descriptors: [SettingDescriptor(.aperture, access: .readOnly)], unsupported: [.zoom])
        let controls = ControlCapabilities(snapshot: snapshot, profile: profile)
        #expect(controls.focus.isOffered)
        #expect(controls.tapFocus.support == .unsupported)
        // A declared iris control over a read-only f-number (a strategy panel) is offered.
        #expect(controls.iris.isOffered)
        #expect(controls.zoom.support == .unsupported, "no flag: the snapshot's unsupported list")
        #expect(controls.ndFilter.support == .unsupported)
        #expect(controls.faceMetering.isOffered)
        #expect(controls.shutter.isOffered, "declared where no descriptor exists")
        #expect(controls.gimbal.support == .unsupported, "a known body without motion has no gimbal")
        #expect(controls.headTracking.support == .unsupported)
    }

    @Test func aWritableSettingWinsOverAFalseFlag() {
        let profile = CameraCaptureProfile(supportsFocusMode: false, supportsZoom: false)
        let snapshot = CapabilitySnapshot(descriptors: [
            SettingDescriptor(.focusPoint), SettingDescriptor(.zoom, domain: SettingDomain(range: 1...4)),
        ])
        let controls = ControlCapabilities(snapshot: snapshot, profile: profile)
        #expect(controls.focus.isOffered)
        #expect(controls.tapFocus.isOffered)
        #expect(controls.zoom.isOffered)
    }

    @Test func motionDecidesGimbalAndHeadTracking() {
        let controls = ControlCapabilities(snapshot: CapabilitySnapshot(),
            profile: CameraCaptureProfile(hasGimbal: true), motion: Self.gimbal)
        #expect(controls.gimbal.isOffered)
        #expect(controls.gimbal.offer == Self.gimbal)
        #expect(controls.headTracking.isOffered)
        var tiltOnly = Self.gimbal
        tiltOnly.axes = [.tilt]
        let tilt = ControlCapabilities(snapshot: CapabilitySnapshot(), profile: nil, motion: tiltOnly)
        #expect(tilt.gimbal.support == .unsupported)
        #expect(tilt.headTracking.support == .unsupported)
        // A body that declares a gimbal but whose motion is not known yet stays unknown.
        let pending = ControlCapabilities(snapshot: CapabilitySnapshot(), profile: CameraCaptureProfile(hasGimbal: true))
        #expect(pending.gimbal.support == .unknown)
    }

    @Test func observationsAreReadouts() {
        let snapshot = CapabilitySnapshot(
            timecodeCapability: .supported(.frames(rate: Rational(25), dropFrame: nil)), audioLevels: .supported)
        let controls = ControlCapabilities(snapshot: snapshot, profile: nil)
        #expect(controls.timecode.isShown && !controls.timecode.isOffered)
        #expect(controls.timecode.offer == .frames(rate: Rational(25), dropFrame: nil))
        #expect(controls.liveAudioLevels.isShown && !controls.liveAudioLevels.isOffered)
        #expect(controls.audio.isOffered, "a body reporting levels has an input to set")
    }

    @Test func codecColorFollowsTheChoicesTheCameraOffers() {
        let colors = CaptureCodecColorChoices(colors: [CaptureCodecColorChoice(id: "log", label: "N-Log")])
        #expect(ControlCapabilities(snapshot: CapabilitySnapshot(), profile: nil, codecColor: colors).codecColor.isOffered)
        let fixed = CaptureCodecColorChoices(colors: [CaptureCodecColorChoice(id: "l3", label: "Log3G10", isEditable: false)])
        let readout = ControlCapabilities(snapshot: CapabilitySnapshot(), profile: nil, codecColor: fixed).codecColor
        #expect(readout.isShown && !readout.isOffered)
        #expect(ControlCapabilities(snapshot: CapabilitySnapshot(), profile: nil, codecColor: .empty).codecColor.support == .unknown)
    }

    @Test func layoutIsAViewThatKeepsTheBaseWhileUnknown() {
        var base = MonitorLayoutCapabilities()
        base.zoom = true
        base.clipStar = true
        let unknown = MonitorLayoutCapabilities(controls: ControlCapabilities(), base: base)
        #expect(unknown == base)
        let profile = CameraCaptureProfile(supportsFocusMode: true, hasGimbal: false, supportsZoom: false)
        let known = MonitorLayoutCapabilities(
            controls: ControlCapabilities(snapshot: CapabilitySnapshot(timecode: .supported), profile: profile), base: base)
        #expect(!known.zoom && known.focus && !known.gimbal && known.timecode && known.clipStar)
    }

    @Test func vectorsRenderOneRowPerFamily() {
        let rows = ControlCapabilityVectors.rows(integration: "fake", body: "Body", ControlCapabilities())
        #expect(rows.count == ControlFamily.allCases.count)
        #expect(rows.first == "fake\tBody\tiso\tunknown")
        let document = ControlCapabilityVectors.document(integration: "fake", bodies: [("Body", ControlCapabilities())])
        #expect(document.hasSuffix("multiview\tunknown\n"))
        #expect(document.hasPrefix("# Generated"))
    }

    @Test func beforeConnectionOnlyTheKnownModelsProfileIsOffered() {
        let none = ControlCapabilities(beforeConnection: nil)
        #expect(none.offered.isEmpty, "no model known: no camera-dependent control")
        #expect(none.audio.support == .unknown)
        let profile = CameraCaptureProfile(supportsFocusMode: true, supportsAperture: false, hasGimbal: true)
        let known = ControlCapabilities(beforeConnection: profile, motion: Self.gimbal)
        #expect(known.focus.isOffered && known.gimbal.isOffered)
        #expect(!known.iris.isOffered)
        #expect(!known.audio.isOffered, "undeclared stays unknown")
        #expect(known == ControlCapabilities(snapshot: CapabilitySnapshot(), profile: profile, motion: Self.gimbal))
    }

    @Test func theStaticProfileDeclaresTheHeaderAccent() {
        #expect(CameraCaptureProfile().headerAccent == .shootingMode,
            "DJI and Insta keep the shooting-mode accent")
        var nikon = CameraCaptureProfile()
        nikon.headerAccent = .codec
        #expect(ControlCapabilities(snapshot: CapabilitySnapshot(), profile: nikon).headerAccent == .codec)
        #expect(ControlCapabilities(beforeConnection: nikon).headerAccent == .codec,
            "the saved body keeps its accent before it reconnects")
        #expect(ControlCapabilities().headerAccent == .shootingMode)
        #expect(ControlCapabilities(snapshot: CapabilitySnapshot(), profile: nil).headerAccent == .shootingMode,
            "no body known never invents a codec accent")
    }
}
