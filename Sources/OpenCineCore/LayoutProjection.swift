import Foundation

/// A compact layout projection for shared UI, kept apart from the domain model.
///
/// The ten fields mirror the UI's existing `MonitorCapabilities` one to one, so the UI can keep
/// its type and map this value into it. They answer "is there a control section to lay out", not
/// "is the control enabled now": availability and observations still come from the snapshot, and
/// read-only settings are readouts, not sections. Support that is still unknown projects to
/// `false` here; that is a layout choice (reserve no space until discovered) and never a
/// statement about telemetry.
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

    public init() {}

    /// Derives `zoom`, `focus` and `iris` from writable settings. The other seven fields have no
    /// Core vocabulary yet and are copied from `base`, which the integration or app supplies.
    public init(_ capabilities: CapabilitySnapshot, base: MonitorLayoutCapabilities = .init()) {
        func writable(_ key: SettingKey) -> Bool { capabilities[key]?.access == .readWrite }
        self = base
        zoom = writable(.zoom)
        focus = writable(.focusMode) || writable(.focusPoint)
        iris = writable(.aperture)
    }
}
