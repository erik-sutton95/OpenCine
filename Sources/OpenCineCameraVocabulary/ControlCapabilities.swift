import Foundation
import OpenCineCore
import OpenCineMotion

/// A user-facing camera control family the shared UI may offer. Host features that do not depend on
/// the camera (assists, relay, watch, settings tabs, local clip stars) are not listed: a difference
/// there between apps is a parity gap, never a camera capability. Kotlin twin: `ControlFamily`.
public enum ControlFamily: String, CaseIterable, Codable, Sendable {
    case iso, shutter, whiteBalance, tint, iris, ndFilter, focus, tapFocus, faceMetering
    case exposureCompensation, codecColor, recordingFormat, audio, liveAudioLevels, zoom
    case gimbal, headTracking, timecode, recording, photo, media, mediaDelete, multiview
}

/// A family with support only, no values to offer.
public struct NoOffer: Hashable, Sendable {
    public init() {}
}

/// Support and access of one family, for readers that do not need its values.
public struct ControlStatus: Hashable, Codable, Sendable {
    public var support: SupportStatus
    public var access: SettingAccess

    public init(support: SupportStatus, access: SettingAccess = .readWrite) {
        self.support = support
        self.access = access
    }

    /// The shared UI offers the control: supported and writable.
    public var isOffered: Bool { support == .supported && access == .readWrite }
    /// The shared UI shows at least its readout.
    public var isShown: Bool { support == .supported }
}

/// One control family: whether the connected camera has it, whether it can be changed, and the
/// typed values it offers. Unknown support is never offered and never "not applicable".
public struct ControlCapability<Offer: Equatable & Sendable>: Equatable, Sendable {
    public var support: SupportStatus
    public var access: SettingAccess
    /// The ladder, range or modes, when the source declared them (never for an unsupported family;
    /// a family still unknown may carry declared values such as its native ISO extensions).
    public var offer: Offer?

    public init(support: SupportStatus, access: SettingAccess = .readWrite, offer: Offer? = nil) {
        self.support = support
        self.access = access
        self.offer = support == .unsupported ? nil : offer
    }

    public static var unknown: Self { Self(support: .unknown) }
    public static var unsupported: Self { Self(support: .unsupported) }
    public static func supported(_ offer: Offer? = nil, access: SettingAccess = .readWrite) -> Self {
        Self(support: .supported, access: access, offer: offer)
    }

    public var status: ControlStatus { ControlStatus(support: support, access: access) }
    public var isOffered: Bool { status.isOffered }
    public var isShown: Bool { status.isShown }
}

/// A setting-backed family's values, straight from its Core descriptor.
public struct SettingOffer: Hashable, Sendable {
    public var domain: SettingDomain?
    public var availability: Availability
    public var semantics: SettingSemantics

    public init(domain: SettingDomain? = nil, availability: Availability = .available,
        semantics: SettingSemantics = .init()) {
        self.domain = domain
        self.availability = availability
        self.semantics = semantics
    }

    public init(_ descriptor: SettingDescriptor) {
        self.init(domain: descriptor.domain, availability: descriptor.availability,
            semantics: descriptor.semantics)
    }
}

/// ISO values plus the declared native extensions (dual-native hop, auto ceiling).
public struct ISOOffer: Equatable, Sendable {
    public var setting: SettingOffer?
    public var autoRangeFloor: Int?
    public var nativeISO: CaptureNativeISOCapabilities

    public init(setting: SettingOffer? = nil, autoRangeFloor: Int? = nil,
        nativeISO: CaptureNativeISOCapabilities = .init()) {
        self.setting = setting
        self.autoRangeFloor = autoRangeFloor
        self.nativeISO = nativeISO
    }
}

/// Recording format values: the common frame-rate descriptor and the body's declared format lists.
public struct RecordingFormatOffer: Equatable, Sendable {
    public var frameRate: SettingOffer?
    public var fallbacks: [ShootingMode: [VideoFormat]]

    public init(frameRate: SettingOffer? = nil, fallbacks: [ShootingMode: [VideoFormat]] = [:]) {
        self.frameRate = frameRate
        self.fallbacks = fallbacks
    }
}

/// The one typed camera capability model the shared UI reads to decide what to offer. Static facts
/// per body come from the integration's `CameraCaptureProfile`; dynamic facts from its revisioned
/// `CapabilitySnapshot` and motion declaration. Apps never set a field to a literal.
public struct ControlCapabilities: Equatable, Sendable {
    public var iso: ControlCapability<ISOOffer>
    public var shutter: ControlCapability<SettingOffer>
    public var whiteBalance: ControlCapability<SettingOffer>
    public var tint: ControlCapability<SettingOffer>
    public var iris: ControlCapability<SettingOffer>
    public var ndFilter: ControlCapability<SettingOffer>
    public var focus: ControlCapability<SettingOffer>
    public var tapFocus: ControlCapability<NoOffer>
    public var faceMetering: ControlCapability<NoOffer>
    public var exposureCompensation: ControlCapability<SettingOffer>
    public var codecColor: ControlCapability<CaptureCodecColorChoices>
    public var recordingFormat: ControlCapability<RecordingFormatOffer>
    /// The camera's audio input settings (the AUDIO tile and sheet).
    public var audio: ControlCapability<NoOffer>
    /// Live audio levels the camera reports (the meter).
    public var liveAudioLevels: ControlCapability<NoOffer>
    public var zoom: ControlCapability<CameraZoomProfile>
    public var gimbal: ControlCapability<MotionCapabilities>
    public var headTracking: ControlCapability<MotionCapabilities>
    public var timecode: ControlCapability<TimecodePrecision>
    public var recording: ControlCapability<NoOffer>
    public var photo: ControlCapability<NoOffer>
    /// The camera's own clip library can be browsed.
    public var media: ControlCapability<NoOffer>
    public var mediaDelete: ControlCapability<NoOffer>
    /// The body can join a multi-camera stage.
    public var multiview: ControlCapability<NoOffer>
    /// Which live header readout carries the app accent, from the body's static profile. The
    /// shared header accents the declared slot only when it shows.
    public var headerAccent: MonitorHeaderAccent

    /// Nothing known: every family unknown.
    public init() {
        iso = .unknown; shutter = .unknown; whiteBalance = .unknown; tint = .unknown
        iris = .unknown; ndFilter = .unknown; focus = .unknown; tapFocus = .unknown
        faceMetering = .unknown; exposureCompensation = .unknown; codecColor = .unknown
        recordingFormat = .unknown; audio = .unknown; liveAudioLevels = .unknown; zoom = .unknown
        gimbal = .unknown; headTracking = .unknown; timecode = .unknown; recording = .unknown
        photo = .unknown; media = .unknown; mediaDelete = .unknown; multiview = .unknown
        headerAccent = .shootingMode
    }

    /// Applies typed backend restrictions without inventing support or values. Missing inputs
    /// retain the camera's facts; unknown inputs withhold controls; read-only never becomes writable.
    public func restricting(_ inputs: [ControlFamily: ControlStatus]) -> Self {
        func restrict<Offer: Equatable & Sendable>(_ value: ControlCapability<Offer>,
            _ family: ControlFamily) -> ControlCapability<Offer> {
            guard let input = inputs[family] else { return value }
            let support: SupportStatus
            if value.support == .unsupported || input.support == .unsupported {
                support = .unsupported
            } else if input.support == .unknown {
                support = .unknown
            } else {
                support = value.support
            }
            let access: SettingAccess = value.access == .readOnly || input.access == .readOnly
                ? .readOnly : .readWrite
            return .init(support: support, access: access, offer: value.offer)
        }
        var result = self
        result.iso = restrict(iso, .iso)
        result.shutter = restrict(shutter, .shutter)
        result.whiteBalance = restrict(whiteBalance, .whiteBalance)
        result.tint = restrict(tint, .tint)
        result.iris = restrict(iris, .iris)
        result.ndFilter = restrict(ndFilter, .ndFilter)
        result.focus = restrict(focus, .focus)
        result.tapFocus = restrict(tapFocus, .tapFocus)
        result.faceMetering = restrict(faceMetering, .faceMetering)
        result.exposureCompensation = restrict(exposureCompensation, .exposureCompensation)
        result.codecColor = restrict(codecColor, .codecColor)
        result.recordingFormat = restrict(recordingFormat, .recordingFormat)
        result.audio = restrict(audio, .audio)
        result.liveAudioLevels = restrict(liveAudioLevels, .liveAudioLevels)
        result.zoom = restrict(zoom, .zoom)
        result.gimbal = restrict(gimbal, .gimbal)
        result.headTracking = restrict(headTracking, .headTracking)
        result.timecode = restrict(timecode, .timecode)
        result.recording = restrict(recording, .recording)
        result.photo = restrict(photo, .photo)
        result.media = restrict(media, .media)
        result.mediaDelete = restrict(mediaDelete, .mediaDelete)
        result.multiview = restrict(multiview, .multiview)
        return result
    }

    /// Support and access of `family`.
    public func status(_ family: ControlFamily) -> ControlStatus {
        switch family {
        case .iso: iso.status
        case .shutter: shutter.status
        case .whiteBalance: whiteBalance.status
        case .tint: tint.status
        case .iris: iris.status
        case .ndFilter: ndFilter.status
        case .focus: focus.status
        case .tapFocus: tapFocus.status
        case .faceMetering: faceMetering.status
        case .exposureCompensation: exposureCompensation.status
        case .codecColor: codecColor.status
        case .recordingFormat: recordingFormat.status
        case .audio: audio.status
        case .liveAudioLevels: liveAudioLevels.status
        case .zoom: zoom.status
        case .gimbal: gimbal.status
        case .headTracking: headTracking.status
        case .timecode: timecode.status
        case .recording: recording.status
        case .photo: photo.status
        case .media: media.status
        case .mediaDelete: mediaDelete.status
        case .multiview: multiview.status
        }
    }

    /// The declared native ISO extensions (dual-native hop, auto ceiling); unknown when not declared.
    public var nativeISO: CaptureNativeISOCapabilities { iso.offer?.nativeISO ?? .init() }

    /// Every family the shared UI offers as a control.
    public var offered: Set<ControlFamily> { Set(ControlFamily.allCases.filter { status($0).isOffered }) }

    /// The one pre-connection rule, the same in every app: before a camera is connected the
    /// shared UI offers only what the static profile of the known camera model declares (a saved
    /// or selected body, or an integration with one model); with no model known it offers no
    /// camera-dependent control (every family unknown).
    public init(beforeConnection profile: CameraCaptureProfile?, motion: MotionCapabilities? = nil,
        codecColor: CaptureCodecColorChoices? = nil) {
        guard let profile else { self.init(); return }
        self.init(snapshot: CapabilitySnapshot(), profile: profile, motion: motion, codecColor: codecColor)
    }

    /// Merges the integration's declarations into one model.
    ///
    /// - `snapshot`: the live, revisioned Core capabilities (descriptors, unsupported keys,
    ///   timecode and audio level support).
    /// - `profile`: the body's static declaration, `nil` while no body is known.
    /// - `motion`: the body's motion service; with a known body `nil` means it has none.
    /// - `codecColor`: the codec and colour choices the camera offers now, when the host has them.
    public init(snapshot: CapabilitySnapshot, profile: CameraCaptureProfile?,
        motion: MotionCapabilities? = nil, codecColor: CaptureCodecColorChoices? = nil) {
        self.init()
        let declared = profile?.controls ?? [:]
        func writable(_ key: SettingKey) -> Bool { snapshot[key]?.access == .readWrite }
        func flag(_ value: Bool?) -> SupportStatus? { value.map { $0 ? .supported : .unsupported } }
        /// Descriptor first, then the static declaration, then the snapshot's unsupported list.
        func setting(_ key: SettingKey, _ family: ControlFamily) -> ControlCapability<SettingOffer> {
            if let descriptor = snapshot[key] {
                return .supported(SettingOffer(descriptor), access: descriptor.access)
            }
            if let status = declared[family], status != .unknown { return .init(support: status) }
            return .init(support: snapshot.support(of: key))
        }
        /// A writable setting wins, then the body's flag, then the snapshot (read-only stays a readout).
        func control(_ keys: [SettingKey], flag declaration: Bool?) -> ControlStatus {
            if keys.contains(where: writable) { return ControlStatus(support: .supported) }
            if let status = flag(declaration) { return ControlStatus(support: status) }
            if let descriptor = keys.lazy.compactMap({ snapshot[$0] }).first {
                return ControlStatus(support: .supported, access: descriptor.access)
            }
            let statuses = keys.map(snapshot.support(of:))
            return ControlStatus(support: statuses.allSatisfy { $0 == .unsupported } ? .unsupported : .unknown)
        }
        func declaredOnly(_ family: ControlFamily) -> ControlCapability<NoOffer> {
            .init(support: declared[family] ?? .unknown)
        }

        let isoSetting = snapshot[.iso].map(SettingOffer.init)
        let isoBase = setting(.iso, .iso)
        iso = .init(support: isoBase.support, access: isoBase.access,
            offer: ISOOffer(setting: isoSetting, autoRangeFloor: profile?.isoAutoRangeFloor,
                nativeISO: profile?.nativeISO ?? .init()))
        shutter = setting(.shutter, .shutter)
        whiteBalance = setting(.whiteBalance, .whiteBalance)
        tint = setting(.whiteBalanceTint, .tint)
        exposureCompensation = setting(.exposureCompensation, .exposureCompensation)
        ndFilter = .init(support: declared[.ndFilter] ?? .unknown)

        // Iris: a declared iris control (for example a variable-iris strategy panel over a
        // read-only f-number) or a writable aperture.
        let irisStatus = control([.aperture], flag: profile?.supportsAperture)
        iris = .init(support: irisStatus.support, access: irisStatus.access,
            offer: snapshot[.aperture].map(SettingOffer.init))
        let focusStatus = control([.focusMode, .focusPoint], flag: profile?.supportsFocusMode)
        focus = .init(support: focusStatus.support, access: focusStatus.access,
            offer: snapshot[.focusMode].map(SettingOffer.init))
        let tapStatus: SupportStatus =
            snapshot.support(of: .focusPoint) == .supported
            ? .supported : flag(profile?.supportsTapFocus) ?? snapshot.support(of: .focusPoint)
        tapFocus = .init(support: tapStatus)
        faceMetering = declaredOnly(.faceMetering)

        let zoomStatus = control([.zoom], flag: profile?.supportsZoom)
        zoom = .init(support: zoomStatus.support, access: zoomStatus.access, offer: profile?.zoom)

        // Audio input settings follow the body's declaration, else live levels (a body that reports
        // levels has an input to set).
        liveAudioLevels = .init(support: snapshot.audioLevels, access: .readOnly)
        audio = .init(support: declared[.audio] ?? snapshot.audioLevels)

        timecode = .init(support: snapshot.timecodeCapability.support, access: .readOnly,
            offer: snapshot.timecodeCapability.precision)
        recording = .init(support: snapshot[.recording] != nil ? .supported : declared[.recording] ?? snapshot.support(of: .recording))
        let frameRate = snapshot[.frameRate].map(SettingOffer.init)
        let fallbacks = profile?.videoFormatFallbacks ?? [:]
        recordingFormat = .init(
            support: declared[.recordingFormat] ?? (frameRate != nil || !fallbacks.isEmpty ? .supported : .unknown),
            offer: RecordingFormatOffer(frameRate: frameRate, fallbacks: fallbacks))

        if let codecColor {
            let any = codecColor.showsCodec || codecColor.showsColor
            self.codecColor = .init(support: any ? .supported : declared[.codecColor] ?? .unknown,
                access: codecColor.codecEditable || codecColor.colorEditable || !any ? .readWrite : .readOnly,
                offer: codecColor)
        } else {
            self.codecColor = .init(support: declared[.codecColor] ?? .unknown)
        }

        // Motion: gimbal when the service drives pan and tilt; head tracking when it also reports
        // the camera's pose. With no body known both stay unknown.
        if let motion {
            let steers = motion.axes.isSuperset(of: [.pan, .tilt])
            gimbal = .init(support: steers ? .supported : .unsupported, offer: motion)
            let pose: SupportStatus = steers ? motion.pose : .unsupported
            headTracking = .init(support: pose, offer: motion)
        } else if profile != nil {
            let none = profile?.hasGimbal == true ? SupportStatus.unknown : .unsupported
            gimbal = .init(support: none)
            headTracking = .init(support: none)
        }

        photo = declaredOnly(.photo)
        media = declaredOnly(.media)
        mediaDelete = declaredOnly(.mediaDelete)
        multiview = declaredOnly(.multiview)
        headerAccent = profile?.headerAccent ?? .shootingMode
    }
}

extension MonitorLayoutCapabilities {
    /// The ten-section layout as a computed view of the one model: a control section lays out
    /// when its family is offered, the timecode slot when the camera reports timecode.
    /// `clipDelete`, `clipStar` and `requiresInternetHop` are host policy and come from `base`; a
    /// family whose support is unknown keeps `base`, as the Core projection does for observations.
    public init(controls: ControlCapabilities, base: MonitorLayoutCapabilities = .init()) {
        func lays(_ status: ControlStatus, else base: Bool, readout: Bool = false) -> Bool {
            switch status.support {
            case .supported: readout ? status.isShown : status.isOffered
            case .unsupported: false
            case .unknown: base
            }
        }
        self = base
        gimbal = lays(controls.gimbal.status, else: base.gimbal)
        headTracking = gimbal && lays(controls.headTracking.status, else: base.headTracking)
        zoom = lays(controls.zoom.status, else: base.zoom)
        focus = lays(controls.focus.status, else: base.focus)
        iris = lays(controls.iris.status, else: base.iris)
        audio = lays(controls.audio.status, else: base.audio)
        timecode = lays(controls.timecode.status, else: base.timecode, readout: true)
    }
}

/// The machine-readable export of the model: one tab-separated row per body and family,
/// `integration body family state`, state one of offered, readout, unsupported, unknown. Integration
/// tests write `Fixtures/control-capabilities-<integration>.tsv` (`OPENCINE_WRITE_FIXTURES=1`) and
/// check it on every run on both platforms; `tools/parity-metrics.py` reads it. Kotlin twin:
/// `ControlCapabilityVectors`.
public enum ControlCapabilityVectors {
    public static let header =
        "# Generated by the integration's ControlCapabilityFixture test; do not edit.\n"
        + "# integration\tbody\tfamily\tstate"

    public static func state(_ status: ControlStatus) -> String {
        switch status.support {
        case .supported: status.access == .readWrite ? "offered" : "readout"
        case .unsupported: "unsupported"
        case .unknown: "unknown"
        }
    }

    /// Every family of `body`, in `ControlFamily` order.
    public static func rows(integration: String, body: String, _ controls: ControlCapabilities) -> [String] {
        ControlFamily.allCases.map {
            [integration, body, $0.rawValue, state(controls.status($0))].joined(separator: "\t")
        }
    }

    /// The whole file for `bodies`, in the given order, ending with a newline.
    public static func document(integration: String, bodies: [(String, ControlCapabilities)]) -> String {
        ([header] + bodies.flatMap { rows(integration: integration, body: $0.0, $0.1) })
            .joined(separator: "\n") + "\n"
    }
}
