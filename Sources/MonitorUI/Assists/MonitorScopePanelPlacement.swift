#if os(iOS)
import MonitorPresentation
import SwiftUI

public typealias MonitorScopeStoredCenter = MonitorPresentation.MonitorScopeStoredCenter
public typealias MonitorScopeCanvasSlot = MonitorPresentation.MonitorScopeCanvasSlot

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

    public static func fittedSize(_ preferred: CGSize, in bounds: CGRect, resizable: Bool = true) -> CGSize {
        let scale = min(
            1, max(1, bounds.width) / max(1, preferred.width),
            max(1, bounds.height - (resizable ? gripBottomExtent : 0)) / max(1, preferred.height))
        return CGSize(
            width: max(1, floor(preferred.width * scale)),
            height: max(1, floor(preferred.height * scale)))
    }

    public static func size(_ preferred: CGSize, canvas: CGRect, clearance: EdgeInsets) -> CGSize {
        guard canvas.width > 1, canvas.height > 1 else { return preferred }
        return fittedSize(preferred, in: bounds(in: canvas, clearance: clearance))
    }

    public static func clamp(_ point: CGPoint, size: CGSize, in bounds: CGRect,
        resizable: Bool = true) -> CGPoint {
        let minX = bounds.minX + size.width / 2
        let minY = bounds.minY + max(size.height / 2,
            (resizable ? gripTopInterior : 0) - size.height / 2)
        return CGPoint(
            x: min(max(minX, point.x), max(minX, bounds.maxX - size.width / 2)),
            y: min(max(minY, point.y), max(minY,
                bounds.maxY - size.height / 2 - (resizable ? gripBottomExtent : 0))))
    }
}

/// Coordinates are normalized against the full canvas; fitting never rewrites storage.
extension MonitorScopeStoredCenter {
    public init(center: CGPoint, in bounds: CGRect) {
        self.init(xFraction: Double((center.x - bounds.minX) / max(bounds.width, 1)),
            yFraction: Double((center.y - bounds.minY) / max(bounds.height, 1)))
    }
    public func center(in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.minX + CGFloat(xFraction) * bounds.width,
            y: bounds.minY + CGFloat(yFraction) * bounds.height)
    }
}

extension MonitorScopeCanvasSlot {
    public static func forBounds(_ bounds: CGRect) -> Self {
        forSize(width: Double(bounds.width), height: Double(bounds.height))
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
    public let resizable: Bool
    public init(baseSize: CGSize, preferredSize: CGSize, center: CGPoint, scale: Double,
        canvas: CGRect, movementBounds: CGRect, resizable: Bool = true) {
        self.baseSize = baseSize; self.scale = scale; self.canvas = canvas
        self.movementBounds = movementBounds
        self.resizable = resizable
        size = MonitorScopePanelPlacement.fittedSize(preferredSize, in: movementBounds, resizable: resizable)
        self.center = MonitorScopePanelPlacement.clamp(center, size: size, in: movementBounds,
            resizable: resizable)
    }
}

public enum MonitorScopePanelMove {
    case began(CGPoint), changed(CGPoint), ended, cancelled(canvas: CGRect)
}

/// Where a movable scope panel starts before fitting: its base size times the operator scale,
/// and the session, saved or default centre kept wholly inside the overlay bounds.
public enum MonitorScopePanelCentering {
    /// Operator scale of the meter panels (traffic lights, ND); scopes clamp through their options.
    public static let scaleRange: ClosedRange<Double> = 0.6...1.6

    public static func clampedScale(_ value: Double) -> Double {
        min(max(value, scaleRange.lowerBound), scaleRange.upperBound)
    }

    public static func panelSize(_ baseSize: CGSize, scale: Double) -> CGSize {
        CGSize(width: (baseSize.width * scale).rounded(), height: (baseSize.height * scale).rounded())
    }

    public static func clamp(_ point: CGPoint, size: CGSize, in bounds: CGRect) -> CGPoint {
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        return CGPoint(
            x: min(max(bounds.minX + halfWidth, point.x), bounds.maxX - halfWidth),
            y: min(max(bounds.minY + halfHeight, point.y), bounds.maxY - halfHeight))
    }

    /// Unplaced panels start at the canvas centre; saved and session centres win later.
    public static func defaultCenter(size: CGSize, bounds: CGRect) -> CGPoint {
        clamp(CGPoint(x: bounds.midX, y: bounds.midY), size: size, in: bounds)
    }

    public static func resolvedCenter(
        session: CGPoint?, stored: MonitorScopeStoredCenter?, defaultCenter: CGPoint,
        size: CGSize, bounds: CGRect
    ) -> CGPoint {
        clamp(session ?? stored?.center(in: bounds) ?? defaultCenter, size: size, in: bounds)
    }
}
#endif
