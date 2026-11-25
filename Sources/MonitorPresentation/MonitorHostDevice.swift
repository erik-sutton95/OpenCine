import OpenCineCore

/// The device the monitor runs on (`OpenCineCore.HostDevice`), by a name the native views can use:
/// they import this layer, not Core. `MonitorHostDevice.current.isLargeScreen` is the one
/// large-screen check (MonitorUI).
public typealias MonitorHostDevice = OpenCineCore.HostDevice
