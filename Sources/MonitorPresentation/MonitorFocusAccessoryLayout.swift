/// Bounds for an optional on-picture focus accessory. Scope normalization stays on the full canvas.
public struct MonitorFocusAccessoryLayout: Equatable, Sendable {
    /// Available picture space, clear of status, readouts, system controls and window insets.
    public let frame: MonitorRect
    /// Short layouts retain transport rather than clipping the setup editor.
    public let compact: Bool

    private let bounds: MonitorRect
    private let preferredPosition: MonitorScopePoint

    /// Position is normalized over available travel; nil retains the original top-right placement.
    public init(layout: FieldMonitorLayout, safeArea: MonitorSafeArea, expanded: Bool,
        position: MonitorScopePoint? = nil) {
        let left = max(layout.picture.x + 12, safeArea.leading + 12)
        let right = min(layout.picture.maxX - 12,
            layout.portrait ? layout.viewport.maxX - safeArea.trailing - 12 : layout.settings.x - 12)
        // Portrait fit leaves too little picture height for fixed controls and setup together.
        // Expanded setup uses the surrounding letterbox; the compact strip stays on the picture.
        let portraitSetup = layout.portrait && expanded
        let top = portraitSetup ? layout.status.maxY + 8 : max(layout.picture.y + 8, layout.status.maxY + 8)
        let pictureFloor = portraitSetup ? layout.viewport.height : layout.picture.maxY
        let floor = min(pictureFloor - 12, layout.viewport.height - safeArea.bottom - 12)
        let bottom = layout.values.height > 0 ? min(floor, layout.values.y - 12) : floor
        let available = max(0, bottom - top)
        compact = !expanded || available < 232
        let width = min(300, max(0, right - left))
        let height = min(available, compact ? 112 : 420)
        bounds = .init(x: left, y: top, width: max(0, right - left), height: available)
        preferredPosition = position ?? .init(x: 1, y: 0)
        frame = .init(
            x: left + min(1, max(0, preferredPosition.x)) * max(0, bounds.width - width),
            y: top + min(1, max(0, preferredPosition.y)) * max(0, available - height),
            width: width, height: height)
    }


    /// Applies a header-drag delta and preserves preference on axes with no available travel.
    public func movedBy(x: Double, y: Double) -> MonitorScopePoint {
        let travelX = bounds.width - frame.width
        let travelY = bounds.height - frame.height
        return .init(
            x: travelX > 0 ? min(1, max(0, (frame.x + x - bounds.x) / travelX)) : preferredPosition.x,
            y: travelY > 0 ? min(1, max(0, (frame.y + y - bounds.y) / travelY)) : preferredPosition.y)
    }

    /// Reserves the larger horizontal region without changing saved scope positions.
    public func reserveSpace(in region: MonitorRect) -> MonitorRect {
        let leftWidth = max(0, min(region.maxX, frame.x - 8) - region.x)
        let rightStart = max(region.x, frame.maxX + 8)
        let rightWidth = max(0, region.maxX - rightStart)
        return rightWidth > leftWidth
            ? .init(x: rightStart, y: region.y, width: rightWidth, height: region.height)
            : .init(x: region.x, y: region.y, width: leftWidth, height: region.height)
    }
}
