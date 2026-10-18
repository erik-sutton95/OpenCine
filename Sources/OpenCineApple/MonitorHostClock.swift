#if os(iOS) || os(macOS) || os(watchOS) || os(tvOS) || os(visionOS)
import OpenCineCore

/// The portable clock accepted by native monitor composition. The alias preserves the same
/// Core value and public initializer type while the composition imports its allowed Apple layer.
public typealias MonitorHostClock = HostClock
#endif
