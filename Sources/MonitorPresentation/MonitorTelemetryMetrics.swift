/// The existing phone and tablet pill sizes and typography, independent of the host device.
/// Renderers retain their native defaults unless a caller declares these metrics explicitly.
public enum MonitorTelemetryMetrics: Equatable, Sendable {
    case phone
    case tablet

    public var pillWidth: Double { self == .tablet ? 64 : 58 }
    public var iconlessWidth: Double { self == .tablet ? 44 : 40 }
    public var pillHeight: Double {
        FieldMonitorLayout.telemetryGaugeHeight(tablet: self == .tablet)
    }
    public var iconSize: Double { self == .tablet ? 12 : 11 }
    public var fontSize: Double { self == .tablet ? 11 : 10 }
    public var barHeight: Double { self == .tablet ? 10 : 9 }
    public var stackSpacing: Double { self == .tablet ? 5 : 4 }
}
