/// What command mode keeps of the live header (hardware pass 1.3). The dashboard's hero carries
/// the record state and the timecode and its tiles the format, so the header never repeats them.
public enum MonitorCommandHeader: Equatable, Sendable {
    /// No header: in landscape the gauge column keeps the link and the dashboard's health strip
    /// storage; a phone's portrait telemetry row keeps both.
    case hidden
    /// Storage and the link only: a portrait tablet has neither the health strip nor the row.
    case telemetry
}

/// The command dashboard replaces the video picture. Its viewport follows the actual header,
/// telemetry and system rails, so changing the video's aspect cannot clip the controls.
/// The Compose twin consumes the same native chrome rectangles and uses the same clearances.
public enum MonitorCommandDashboardLayout {
    /// The header command mode draws beside the dashboard. Kotlin twin: `header(layout)`.
    public static func header(layout: FieldMonitorLayout) -> MonitorCommandHeader {
        layout.portrait && layout.tablet ? .telemetry : .hidden
    }

    /// The dashboard viewport. Without a header the dashboard takes the header's place: in
    /// portrait just under the telemetry row, in landscape level with the top of the side rails.
    /// `minimumTop` is the lowest point the measured telemetry row occupies (a wrapped power row).
    public static func frame(layout: FieldMonitorLayout, minimumTop: Double = 0) -> MonitorRect {
        let headed = header(layout: layout) == .telemetry
        let leading: Double
        let trailing: Double
        var top: Double
        let bottom: Double
        if layout.portrait {
            leading = max(16, layout.status.x)
            trailing = min(layout.viewport.maxX - 16, layout.status.maxX)
            top =
                headed
                ? max(layout.status.maxY, layout.telemetry.maxY) + 12
                : max(layout.status.y, layout.telemetry.maxY + 12)
            bottom = layout.system.y - 12
        } else {
            leading = max(layout.lock.maxX, layout.gauges.maxX) + 12
            trailing =
                min(layout.settings.x, layout.media.x, layout.record.x, layout.display.x) - 12
            top = headed ? layout.status.maxY + 18 : max(layout.status.y, layout.lock.y)
            // Values retain the bottom-safe-area anchor even when command mode hides them.
            bottom = layout.values.maxY - 4
        }
        top = max(top, minimumTop)
        return MonitorRect(
            x: leading, y: top, width: max(1, trailing - leading), height: max(44, bottom - top))
    }
}
