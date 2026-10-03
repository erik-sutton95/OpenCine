#if os(iOS)
import SwiftUI

/// Scope bodies have equal horizontal margins in the space reserved for overlays.
/// The corner stays visible; its expanded touch area may extend past a side boundary.
/// Stored centres remain relative to the full canvas, so rotation does not rewrite preferences.
public enum MonitorScopePanelPlacement {
    public static let padding: CGFloat = 8
    public static let gripExtent: CGFloat = 44
    public static let gripInterior: CGFloat = 12
    public static let gripBottomExtent: CGFloat = 12
    public static let gripTopInterior: CGFloat = 44

    public static func bounds(in canvas: CGRect, clearance: EdgeInsets = EdgeInsets()) -> CGRect {
        let left = canvas.minX + max(0, clearance.leading) + padding
        let top = canvas.minY + max(0, clearance.top) + padding
        let right = canvas.maxX - max(0, clearance.trailing) - padding
        let bottom = canvas.maxY - max(0, clearance.bottom) - padding
        return CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
    }

    public static func isUsable(_ bounds: CGRect) -> Bool {
        bounds.width >= gripExtent + gripInterior && bounds.height >= gripExtent + gripInterior
    }

    public static func fittedSize(_ preferred: CGSize, in bounds: CGRect) -> CGSize {
        let scale = min(
            1, max(1, bounds.width) / max(1, preferred.width),
            max(1, bounds.height - gripBottomExtent) / max(1, preferred.height))
        return CGSize(
            width: max(1, floor(preferred.width * scale)),
            height: max(1, floor(preferred.height * scale)))
    }

    public static func size(_ preferred: CGSize, canvas: CGRect, clearance: EdgeInsets) -> CGSize {
        guard canvas.width > 1, canvas.height > 1 else { return preferred }
        return fittedSize(preferred, in: bounds(in: canvas, clearance: clearance))
    }

    public static func clamp(_ point: CGPoint, size: CGSize, in bounds: CGRect) -> CGPoint {
        let minX = bounds.minX + size.width / 2
        let minY = bounds.minY + max(size.height / 2, gripTopInterior - size.height / 2)
        return CGPoint(
            x: min(max(minX, point.x), max(minX, bounds.maxX - size.width / 2)),
            y: min(max(minY, point.y), max(minY, bounds.maxY - size.height / 2 - gripBottomExtent)))
    }
}

/// Coordinates are normalized against the full canvas; fitting never rewrites storage.
public struct MonitorScopeStoredCenter: Codable, Equatable, Sendable {
    public var xFraction: Double
    public var yFraction: Double
    public init(center: CGPoint, in bounds: CGRect) {
        xFraction = Double((center.x - bounds.minX) / max(bounds.width, 1))
        yFraction = Double((center.y - bounds.minY) / max(bounds.height, 1))
    }
    public func center(in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.minX + CGFloat(xFraction) * bounds.width,
            y: bounds.minY + CGFloat(yFraction) * bounds.height)
    }
}

public enum MonitorScopeCanvasSlot: String, Sendable {
    case landscape, portrait
    public static func forBounds(_ bounds: CGRect) -> Self {
        bounds.height > bounds.width ? .portrait : .landscape
    }
    public static func pick<T>(_ landscape: T?, _ portrait: T?, in bounds: CGRect) -> T? {
        forBounds(bounds) == .portrait ? portrait : landscape
    }
    public static func assign<T>(_ landscape: inout T?, _ portrait: inout T?, in bounds: CGRect, _ value: T?) {
        if forBounds(bounds) == .portrait { portrait = value } else { landscape = value }
    }
}

public enum MonitorScopePanelSize {
    public static let waveform = CGSize(width: 250, height: 153)
    public static let parade = CGSize(width: 250, height: 153)
    public static let histogram = CGSize(width: 250, height: 77)
    public static let vectorscope = CGSize(width: 190, height: 190)
    public static let trafficLights = CGSize(width: 74, height: 168)
    public static let ndMeter = CGSize(width: 84, height: 30)
}

/// One immutable view of the panel geometry and operator scale.
public struct MonitorScopePanelLayout: Equatable {
    public let baseSize: CGSize
    public let size: CGSize
    public let center: CGPoint
    public let scale: Double
    public let canvas: CGRect
    public let movementBounds: CGRect
    public init(baseSize: CGSize, preferredSize: CGSize, center: CGPoint, scale: Double,
        canvas: CGRect, movementBounds: CGRect) {
        self.baseSize = baseSize; self.scale = scale; self.canvas = canvas
        self.movementBounds = movementBounds
        size = MonitorScopePanelPlacement.fittedSize(preferredSize, in: movementBounds)
        self.center = MonitorScopePanelPlacement.clamp(center, size: size, in: movementBounds)
    }
}

public enum MonitorScopePanelMove {
    case began(CGPoint), changed(CGPoint), ended, cancelled(canvas: CGRect)
}
#endif
