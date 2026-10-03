#if os(iOS)
import MonitorPresentation
import MonitorUI
import SwiftUI
import UIKit

extension MonitorScopePoint {
    public init(_ point: CGPoint) { self.init(x: Double(point.x), y: Double(point.y)) }
    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}
extension MonitorRect {
    public init(_ rect: CGRect) {
        self.init(x: Double(rect.minX), y: Double(rect.minY),
            width: Double(rect.width), height: Double(rect.height))
    }
}

/// Native bindings convert coordinates; the shared owner performs all mutations and persistence.
extension MonitorScopePanelStore {
    public var optionsBinding: Binding<Options> {
        Binding(get: { self.options }, set: { self.options = $0 })
    }
    public var sessionCenter: CGPoint? {
        get { sessionPosition?.cgPoint }
        set { sessionPosition = newValue.map(MonitorScopePoint.init) }
    }
    public var sessionCenterPortrait: CGPoint? {
        get { sessionPositionPortrait?.cgPoint }
        set { sessionPositionPortrait = newValue.map(MonitorScopePoint.init) }
    }
    public func presentationScale(in bounds: CGRect, tablet: Bool? = nil) -> Double {
        presentationScale(width: Double(bounds.width), height: Double(bounds.height),
            tablet: tablet ?? (UIDevice.current.userInterfaceIdiom == .pad))
    }
    public func sessionCenter(in bounds: CGRect) -> CGPoint? {
        sessionPosition(in: MonitorScopeCanvasSlot.forBounds(bounds))?.cgPoint
    }
    public func storedCenter(in bounds: CGRect) -> MonitorScopeStoredCenter? {
        storedCenter(in: MonitorScopeCanvasSlot.forBounds(bounds))
    }
    public func beginDrag(center: CGPoint, in bounds: CGRect) {
        beginDrag(center: MonitorScopePoint(center), slot: MonitorScopeCanvasSlot.forBounds(bounds))
    }
    public func drag(to center: CGPoint, in bounds: CGRect) { beginDrag(center: center, in: bounds) }
    public func cancelDrag(bounds: CGRect) { cancelDrag(slot: MonitorScopeCanvasSlot.forBounds(bounds)) }
    public func endDrag(bounds: CGRect) { endDrag(canvas: MonitorRect(bounds)) }
}
extension MonitorAudioStoredCenter {
    public init(_ center: CGPoint, in bounds: CGRect) {
        self.init(x: Double((center.x - bounds.minX) / max(1, bounds.width)),
            y: Double((center.y - bounds.minY) / max(1, bounds.height)))
    }
    public func point(in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.minX + (x.isFinite ? x : 0.5) * bounds.width,
            y: bounds.minY + (y.isFinite ? y : 0.5) * bounds.height)
    }
}
extension MonitorAudioPreferenceStore {
    public func storedCenter(in bounds: CGRect) -> MonitorAudioStoredCenter? {
        storedCenter(in: MonitorScopeCanvasSlot.forBounds(bounds))
    }
    public func setCenter(_ center: CGPoint, in bounds: CGRect) {
        setCenter(MonitorScopePoint(center), canvas: MonitorRect(bounds))
    }
}
extension MonitorFalseColorReferencePositions.Center {
    public init(_ point: CGPoint, in bounds: CGRect) {
        self.init(x: Double((point.x - bounds.minX) / max(1, bounds.width)),
            y: Double((point.y - bounds.minY) / max(1, bounds.height)))
    }
    public func point(in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.minX + (x.isFinite ? x : 0.5) * bounds.width,
            y: bounds.minY + (y.isFinite ? y : 0.5) * bounds.height)
    }
}
extension MonitorFalseColorReferencePositions {
    public func center(in bounds: CGRect, size: CGSize, movement: CGRect) -> CGPoint {
        let stored = MonitorScopeCanvasSlot.pick(landscape, portrait, in: bounds)
        return MonitorScopePanelPlacement.clamp(
            stored?.point(in: bounds) ?? CGPoint(x: bounds.midX, y: bounds.midY),
            size: size, in: movement)
    }
}
extension MonitorFalseColorReferencePositionStore {
    public func setCenter(_ center: CGPoint, in bounds: CGRect) {
        setCenter(MonitorScopePoint(center), canvas: MonitorRect(bounds))
    }
}
#endif
