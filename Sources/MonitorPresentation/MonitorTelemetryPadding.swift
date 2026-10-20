import Foundation

/// Preserve complete native content; only decorative pill padding yields to an occupied target budget.
public struct MonitorTelemetryPadding: Equatable, Sendable {
    public let width: Double
    public let padding: Double
    public let fits: Bool

    public init(contentWidth: Double, availableWidth: Double, preferredWidth: Double,
        minimumTarget: Double, scale: Double) {
        let scale = scale.isFinite && scale > 0 ? scale : 1
        let content = ceil(max(0, contentWidth) * scale)
        let preferred = ceil(max(minimumTarget, preferredWidth) * scale)
        let available = availableWidth.isFinite ? floor(max(0, availableWidth) * scale) : .infinity
        let fullPadding = floor(6 * scale)
        if available >= preferred, content + 2 * fullPadding <= preferred {
            width = preferred / scale
            padding = fullPadding / scale
        } else {
            let inset = min(fullPadding, max(0, floor((available - content) / 2)))
            width = max(ceil(minimumTarget * scale), content + 2 * inset) / scale
            padding = inset / scale
        }
        fits = width * scale <= available
    }
}

/// Horizontal budget from the real three occupied controls, independent of native view ownership.
public struct MonitorCompactTelemetryBudget: Equatable, Sendable {
    public let leading: Double
    public let storageWidth: Double
    public let performanceX: Double
    public let performanceWidth: Double
    public let powerX: Double
    public let wrapsPower: Bool

    public init(layout: FieldMonitorLayout, safeLeading: Double, safeTrailing: Double,
        storageWidth: Double, powerWidth: Double, linkWidth: Double, minimumTarget: Double,
        scale: Double, minimumLinkWidth: Double = 0) {
        let scale = scale.isFinite && scale > 0 ? scale : 1
        let storage = storageWidth > 0 ? ceil(max(minimumTarget, storageWidth) * scale) / scale : 0
        let power = ceil(max(0, powerWidth) * scale) / scale
        let storageGap = storage > 0 && linkWidth > 0 ? 8.0 : 0
        let powerGap = (storage > 0 || linkWidth > 0) && power > 0 ? 8.0 : 0
        let originalLeading = max(layout.status.x, safeLeading)
        let originalTrailing = max(layout.viewport.width - layout.status.maxX, safeTrailing)
        let originalBudget = floor((layout.viewport.width - originalLeading - originalTrailing
            - storage - power - storageGap - powerGap) * scale)
        let keepsCorners = originalBudget >= ceil(max(0, linkWidth) * scale)
        leading = keepsCorners ? originalLeading : ceil(max(14, safeLeading) * scale) / scale
        let trailing = keepsCorners ? originalTrailing : ceil(max(14, safeTrailing) * scale) / scale
        self.storageWidth = storage
        performanceX = leading + storage + storageGap
        powerX = layout.viewport.width - trailing - power
        let remaining = floor((powerX - powerGap - performanceX) * scale) / scale
        let singleRowWidth = max(0, remaining)
        let requiredLink = linkWidth > 0 ? ceil(max(minimumTarget, minimumLinkWidth) * scale) / scale : 0
        wrapsPower = power > 0 && (storage > 0 || linkWidth > 0) && requiredLink > remaining
        performanceWidth = wrapsPower
            ? max(0, floor((layout.viewport.width - trailing - performanceX) * scale) / scale)
            : singleRowWidth
    }
}

/// The camera housing at the top of a portrait phone, in viewport points.
public enum MonitorTopCutout {
    /// iOS reports only the safe-area top a cutout produces, not its shape. A portrait iPhone whose
    /// inset is at least 51 pt carries a centred Dynamic Island 126 pt wide; its band here (11 to
    /// 51 pt) covers every model. A notch or no cutout reports nil. Android reads the real rectangle.
    public static func estimated(width: Double, height: Double, safeTop: Double) -> MonitorRect? {
        guard height > width, width < 600, safeTop >= 51 else { return nil }
        return MonitorRect(x: (width - 126) / 2, y: 11, width: 126, height: 40)
    }
}

extension MonitorCompactTelemetryBudget {
    /// Space kept between the leading telemetry and the cutout's edge.
    public static let cutoutClearance = 6.0

    /// The widest storage that keeps storage and the link pill left of a top cutout the telemetry
    /// band crosses. Nil when no cutout crosses it, or when that leading space cannot hold a
    /// minimum storage target and the link (a wide notch): the row keeps its original corners.
    /// The compact row passes the link's minimum width (its pill without decorative padding), so
    /// an ordinary capacity such as "521GB" keeps a readable size and the link pill gives up its
    /// padding first (`linkWidthBeforeCutout`).
    public static func storageWidthBeforeCutout(layout: FieldMonitorLayout, topCutout: MonitorRect?,
        linkWidth: Double, minimumTarget: Double) -> Double? {
        guard let cutout = crossingCutout(layout: layout, topCutout: topCutout) else { return nil }
        let width = cutout.x - cutoutClearance - layout.status.x - linkWidth - (linkWidth > 0 ? 8 : 0)
        return width >= minimumTarget ? width : nil
    }

    /// The widest link pill that starts at `linkX` and still ends `cutoutClearance` before a top
    /// cutout the telemetry band crosses; nil when no cutout crosses it.
    public static func linkWidthBeforeCutout(layout: FieldMonitorLayout, topCutout: MonitorRect?,
        linkX: Double) -> Double? {
        guard let cutout = crossingCutout(layout: layout, topCutout: topCutout) else { return nil }
        return max(0, cutout.x - cutoutClearance - linkX)
    }

    private static func crossingCutout(layout: FieldMonitorLayout, topCutout: MonitorRect?) -> MonitorRect? {
        guard let cutout = topCutout, cutout.y < layout.telemetry.maxY, cutout.maxY > layout.telemetry.y,
            cutout.x > layout.status.x else { return nil }
        return cutout
    }
}
