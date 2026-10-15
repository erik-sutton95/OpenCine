import Foundation

/// A compact layout projection for shared UI, kept apart from the domain model, and the one
/// layout type (the conformance profile declares its review body in it too). The ten fields
/// answer "is there a control section to lay out", not "is the control enabled now":
/// availability and observations still come from the snapshot, and
/// read-only settings are readouts, not sections. A setting whose support is still unknown
/// projects to `false` (reserve no space until discovered); an observation whose support is
/// still unknown keeps the `base` value. Neither is a statement about telemetry.
public struct MonitorLayoutCapabilities: Hashable, Sendable {
    public var gimbal = false
    public var zoom = false
    public var focus = false
    public var iris = false
    public var audio = false
    public var headTracking = false
    public var clipDelete = false
    public var clipStar = false
    public var requiresInternetHop = false
    public var timecode = false

    public init(
        gimbal: Bool = false, zoom: Bool = false, focus: Bool = false, iris: Bool = false,
        audio: Bool = false, headTracking: Bool = false, clipDelete: Bool = false,
        clipStar: Bool = false, requiresInternetHop: Bool = false, timecode: Bool = false
    ) {
        self.gimbal = gimbal
        self.zoom = zoom
        self.focus = focus
        self.iris = iris
        self.audio = audio
        self.headTracking = headTracking
        self.clipDelete = clipDelete
        self.clipStar = clipStar
        self.requiresInternetHop = requiresInternetHop
        self.timecode = timecode
    }

    /// Derives `zoom`, `focus` and `iris` from writable settings, and `timecode` and `audio`
    /// from observation support (audio means live levels; clip audio metadata never turns it on).
    /// `gimbal` and `headTracking` come from the optional motion product's overload; the other
    /// three fields have no Core vocabulary yet. Everything not derived is copied from `base`,
    /// which the integration or app supplies.
    public init(_ capabilities: CapabilitySnapshot, base: MonitorLayoutCapabilities = .init()) {
        func writable(_ key: SettingKey) -> Bool { capabilities[key]?.access == .readWrite }
        func shown(_ support: SupportStatus, else base: Bool) -> Bool {
            switch support {
            case .supported: true
            case .unsupported: false
            case .unknown: base
            }
        }
        self = base
        zoom = writable(.zoom)
        focus = writable(.focusMode) || writable(.focusPoint)
        iris = writable(.aperture)
        timecode = shown(capabilities.timecode, else: base.timecode)
        audio = shown(capabilities.audioLevels, else: base.audio)
    }
}
