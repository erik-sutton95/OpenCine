/// The command dashboard replaces the video picture. Its viewport follows the actual header,
/// telemetry and system rails, so changing the video's aspect cannot clip the controls.
/// The Compose twin consumes the same native chrome rectangles and uses the same clearances.
public enum MonitorCommandDashboardLayout {
    public static func frame(layout: FieldMonitorLayout) -> MonitorRect {
        let leading: Double
        let trailing: Double
        let top: Double
        let bottom: Double
        if layout.portrait {
            leading = max(16, layout.status.x)
            trailing = min(layout.viewport.maxX - 16, layout.status.maxX)
            top = max(layout.status.maxY, layout.telemetry.maxY) + 12
            bottom = layout.system.y - 12
        } else {
            leading = max(layout.lock.maxX, layout.gauges.maxX) + 12
            trailing =
                min(layout.settings.x, layout.media.x, layout.record.x, layout.display.x) - 12
            top = layout.status.maxY + 18
            // Values retain the bottom-safe-area anchor even when command mode hides them.
            bottom = layout.values.maxY - 4
        }
        return MonitorRect(
            x: leading, y: top, width: max(1, trailing - leading), height: max(44, bottom - top))
    }
}
