import Foundation

/// A reversible selection sweep over the catalog's displayed order. Only newly
/// crossed indices change; selections outside the sweep retain their prior state.
public struct MonitorMediaDragSelection: Sendable {
    public private(set) var selectedIDs: Set<String>
    private let ids: [String]
    private let original: Set<String>
    private let origin: Int
    private let selects: Bool
    private var endpoint: Int

    public init?(orderedIDs: [String], originID: String, selectedIDs: Set<String>) {
        guard let index = orderedIDs.firstIndex(of: originID) else { return nil }
        ids = orderedIDs
        original = selectedIDs
        self.selectedIDs = selectedIDs
        origin = index
        endpoint = index
        selects = !selectedIDs.contains(originID)
        apply(index, sweeping: true)
    }

    /// Returns false when the pointer remains in the same item. Callers need not
    /// publish selection or rebuild a set on every pointer/display callback.
    @discardableResult public mutating func move(to index: Int) -> Bool {
        let next = min(ids.count - 1, max(0, index))
        guard next != endpoint else { return false }
        let oldLow = min(origin, endpoint)
        let oldHigh = max(origin, endpoint)
        let newLow = min(origin, next)
        let newHigh = max(origin, next)
        if oldLow < newLow {
            for i in oldLow..<newLow { apply(i, sweeping: false) }
        }
        if newHigh < oldHigh {
            for i in (newHigh + 1)...oldHigh { apply(i, sweeping: false) }
        }
        if newLow < oldLow {
            for i in newLow..<oldLow { apply(i, sweeping: true) }
        }
        if oldHigh < newHigh {
            for i in (oldHigh + 1)...newHigh { apply(i, sweeping: true) }
        }
        endpoint = next
        return true
    }

    private mutating func apply(_ index: Int, sweeping: Bool) {
        let id = ids[index]
        if sweeping ? selects : original.contains(id) {
            selectedIDs.insert(id)
        } else {
            selectedIDs.remove(id)
        }
    }
}

/// Native selection input policy. The standard movement tolerance is 8pt on
/// Swift and 5dp on Compose, preserving each existing native host's default.
public struct MonitorMediaSelectionConfiguration: Equatable, Sendable {
    public enum EdgeCurve: Equatable, Sendable { case quadratic, linear }

    public let holdMilliseconds: Int
    public let movementTolerance: Double
    /// False leaves browsing entry and opening to the actual catalog cells.
    /// The host ignores that whole browsing touch, even if a child enters selection.
    public let allowsSelectionEntry: Bool
    public let sweepsSideways: Bool
    public let edgeBand: Double
    public let maximumEdgeSpeed: Double
    public let edgeCurve: EdgeCurve
    /// A nil limit retains the supplied fixed edge band on compact viewports.
    public let viewportEdgeLimitRatio: Double?
    public let roundsScrollSteps: Bool

    public init(
        holdMilliseconds: Int = 280, movementTolerance: Double = 8,
        allowsSelectionEntry: Bool = true, sweepsSideways: Bool = true,
        edgeBand: Double = 56, maximumEdgeSpeed: Double = 720,
        edgeCurve: EdgeCurve = .quadratic, viewportEdgeLimitRatio: Double? = 1 / 3,
        roundsScrollSteps: Bool = false
    ) {
        precondition(holdMilliseconds >= 0)
        precondition(movementTolerance.isFinite && movementTolerance >= 0)
        precondition(edgeBand.isFinite && edgeBand > 0)
        precondition(maximumEdgeSpeed.isFinite && maximumEdgeSpeed >= 0)
        if let ratio = viewportEdgeLimitRatio {
            precondition(ratio.isFinite && ratio > 0 && ratio <= 0.5)
        }
        self.holdMilliseconds = holdMilliseconds
        self.movementTolerance = movementTolerance
        self.allowsSelectionEntry = allowsSelectionEntry
        self.sweepsSideways = sweepsSideways
        self.edgeBand = edgeBand
        self.maximumEdgeSpeed = maximumEdgeSpeed
        self.edgeCurve = edgeCurve
        self.viewportEdgeLimitRatio = viewportEdgeLimitRatio
        self.roundsScrollSteps = roundsScrollSteps
    }

    public static let standard = Self()
}

public enum MonitorMediaSelectionFeedback: Equatable, Sendable { case began, changed }

/// Native scroll hosts integrate this velocity against their display clock.
public enum MonitorMediaSelectionScroll {
    public static func step(
        pointerY: Double, viewportHeight: Double, elapsed: Double, scale: Double = 1,
        configuration: MonitorMediaSelectionConfiguration = .standard
    ) -> Double {
        guard elapsed.isFinite && elapsed > 0 else { return 0 }
        let density = scale.isFinite && scale > 0 ? scale : 1
        let value =
            velocity(
                pointerY: pointerY / density, viewportHeight: viewportHeight / density,
                configuration: configuration) * density * min(0.05, elapsed)
        return configuration.roundsScrollSteps ? value.rounded() : value
    }

    public static func velocity(pointerY: Double, viewportHeight: Double) -> Double {
        velocity(pointerY: pointerY, viewportHeight: viewportHeight, configuration: .standard)
    }

    public static func velocity(
        pointerY: Double, viewportHeight: Double,
        configuration: MonitorMediaSelectionConfiguration
    ) -> Double {
        guard pointerY.isFinite, viewportHeight.isFinite, viewportHeight > 0 else { return 0 }
        let edge =
            configuration.viewportEdgeLimitRatio.map {
                min(configuration.edgeBand, viewportHeight * $0)
            } ?? configuration.edgeBand
        func speed(_ strength: Double) -> Double {
            configuration.maximumEdgeSpeed
                * (configuration.edgeCurve == .quadratic ? strength * strength : strength)
        }
        if pointerY < edge {
            let strength = min(1, max(0, (edge - pointerY) / edge))
            return -speed(strength)
        }
        if pointerY > viewportHeight - edge {
            let strength = min(1, max(0, (pointerY - viewportHeight + edge) / edge))
            return speed(strength)
        }
        return 0
    }
}

/// Portable hold/range authority. Native hosts supply real positions, visible
/// hits and clock values; retiring a binding keeps only its last published set.
public struct MonitorMediaSelectionController: Sendable {
    public enum News: Equatable, Sendable {
        case open(String)
        case selection(
            selecting: Bool, selected: Set<String>, feedback: MonitorMediaSelectionFeedback?)
    }

    public var movementTolerance: Double
    public var holdMilliseconds: Int
    public var configuration: MonitorMediaSelectionConfiguration {
        didSet { if oldValue != configuration { cancel() } }
    }
    public private(set) var ids: [String] = []
    public private(set) var selecting = false
    public private(set) var selected: Set<String> = []
    public var consuming: Bool { sweep != nil }
    public var canBegin: Bool { pointerDown && acceptsTouch && downID != nil && sweep == nil }
    public private(set) var fingerX: Double = 0
    public private(set) var fingerY: Double = 0
    private var indices: [String: Int] = [:]
    private var context = ""
    private var pointerDown = false
    private var acceptsTouch = false
    private var downX: Double = 0
    private var downY: Double = 0
    private var downTime = 0
    private var downID: String?
    private var moved = false
    private var scrollLocked = false
    private var sweep: MonitorMediaDragSelection?
    // Where the pointer rested when the viewport last changed size under a live sweep (nil: armed).
    private var edgeRestY: Double?

    public init(
        movementTolerance: Double = 8, holdMilliseconds: Int = 280,
        configuration: MonitorMediaSelectionConfiguration = .standard
    ) {
        self.movementTolerance = movementTolerance
        self.holdMilliseconds = holdMilliseconds
        self.configuration = configuration
    }

    public func contains(_ id: String) -> Bool { indices[id] != nil }

    public mutating func bind(
        ids: [String], selecting: Bool, selected: Set<String>, context: String = ""
    ) {
        if self.selecting && !selecting { cancel() }
        if ids != self.ids || context != self.context {
            cancel()
            self.ids = ids
            indices = Dictionary(
                ids.enumerated().map { ($0.element, $0.offset) },
                uniquingKeysWith: { a, _ in a })
            self.context = context
        }
        if sweep == nil {
            self.selecting = selecting
            self.selected = selected
        }
    }

    public mutating func down(id: String?, x: Double, y: Double, timeMilliseconds: Int) {
        pointerDown = true
        acceptsTouch = selecting || configuration.allowsSelectionEntry
        downID = id.flatMap { indices[$0] == nil ? nil : $0 }
        downX = x
        downY = y
        downTime = timeMilliseconds
        moved = false
        scrollLocked = false
        fingerX = x
        fingerY = y
    }

    public mutating func move(id: String?, x: Double, y: Double) -> News? {
        guard pointerDown && acceptsTouch else { return nil }
        fingerX = x
        fingerY = y
        let dx = x - downX
        let dy = y - downY
        if dx * dx + dy * dy >= movementTolerance * movementTolerance { moved = true }
        if moved && selecting && sweep == nil && !scrollLocked
            && (!configuration.sweepsSideways || abs(dy) >= abs(dx))
        {
            scrollLocked = true
        }
        if sweep != nil { return hover(id: id) }
        if configuration.sweepsSideways && selecting && moved && !scrollLocked {
            guard let origin = downID ?? id else { return nil }
            let started = begin(id: origin)
            return hover(id: id) ?? started
        }
        return nil
    }

    public func shouldYieldToScroll() -> Bool {
        pointerDown && sweep == nil && moved && (!selecting || scrollLocked)
    }

    public mutating func holdDue(timeMilliseconds: Int) -> News? {
        guard pointerDown && acceptsTouch && !moved && sweep == nil,
            timeMilliseconds - downTime >= holdMilliseconds, let id = downID
        else { return nil }
        return begin(id: id)
    }

    public mutating func up(childConsumed: Bool) -> News? {
        guard pointerDown else { return nil }
        pointerDown = false
        guard acceptsTouch else { return nil }
        let active = sweep
        sweep = nil
        guard active == nil && !childConsumed && !moved, let id = downID else { return nil }
        if selecting {
            if !selected.insert(id).inserted { selected.remove(id) }
            return .selection(selecting: true, selected: selected, feedback: .changed)
        }
        return .open(id)
    }

    public mutating func cancel() {
        pointerDown = false
        acceptsTouch = false
        sweep = nil
        moved = false
        scrollLocked = false
        downID = nil
        edgeRestY = nil
    }

    /// The viewport changed size under a live sweep (the selection tray appears when the sweep
    /// begins). That can put a pointer that never moved inside an edge band; edge scrolling then
    /// waits until the pointer itself moves vertically by `movementTolerance` from `pointerY`
    /// (viewport-local), so the layout alone never scrolls the gallery and widens the range. A still
    /// hold at the edge of an unchanged viewport still scrolls.
    public mutating func viewportResized(pointerY: Double) {
        if consuming && pointerDown { edgeRestY = pointerY }
    }

    /// The edge velocity for a viewport-local pointer, zero while a resize holds the edge.
    public mutating func edgeVelocity(pointerY: Double, viewportHeight: Double) -> Double {
        guard consuming && pointerDown else { return 0 }
        if let rest = edgeRestY {
            guard abs(pointerY - rest) >= movementTolerance else { return 0 }
            edgeRestY = nil
        }
        return MonitorMediaSelectionScroll.velocity(
            pointerY: pointerY, viewportHeight: viewportHeight, configuration: configuration)
    }

    public func edgeScroll(elapsed: Double, viewportHeight: Double, scale: Double = 1) -> Double {
        guard consuming && pointerDown && elapsed.isFinite && elapsed > 0 else { return 0 }
        if let rest = edgeRestY, abs(fingerY - rest) < movementTolerance { return 0 }
        return MonitorMediaSelectionScroll.step(
            pointerY: fingerY, viewportHeight: viewportHeight, elapsed: elapsed,
            scale: scale, configuration: configuration)
    }

    public mutating func afterScroll(hitID: String?) -> News? {
        guard consuming else { return nil }
        return hover(id: hitID)
    }

    private mutating func begin(id: String) -> News? {
        guard
            let next = MonitorMediaDragSelection(
                orderedIDs: ids, originID: id, selectedIDs: selected)
        else { return nil }
        sweep = next
        edgeRestY = nil
        selecting = true
        selected = next.selectedIDs
        return .selection(selecting: true, selected: selected, feedback: .began)
    }

    private mutating func hover(id: String?) -> News? {
        guard let id, let index = indices[id], sweep?.move(to: index) == true,
            let next = sweep?.selectedIDs
        else { return nil }
        selected = next
        return .selection(selecting: true, selected: next, feedback: .changed)
    }
}
