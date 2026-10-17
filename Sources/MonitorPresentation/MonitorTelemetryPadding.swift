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
