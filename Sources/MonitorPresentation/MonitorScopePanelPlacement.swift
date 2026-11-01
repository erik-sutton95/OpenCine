import Foundation

/// Persisted centers stay normalized against the full canvas. Native layout never rewrites storage.
public struct MonitorScopeStoredCenter: Codable, Equatable, Sendable {
    public var xFraction: Double
    public var yFraction: Double
    public init(xFraction: Double, yFraction: Double) {
        self.xFraction = xFraction; self.yFraction = yFraction
    }
}

public enum MonitorScopeCanvasSlot: String, Sendable {
    case landscape, portrait
    public static func forSize(width: Double, height: Double) -> Self {
        height > width ? .portrait : .landscape
    }
}

/// Where a floating scope or meter may rest beside the live chrome. One rule for every panel,
/// orientation and fit or fill: the panel's frame (its body and the strip below it that the
/// resize corner takes) keeps `gap` from every chrome rect, as it keeps its padding from a screen
/// edge. A drag or a restored centre that lands on chrome moves to the nearest clear centre, so a
/// panel still reaches each edge wherever no control stands there (owner hardware pass
/// 2026-10-30: never under the record button, DISP, Settings, Media or the timecode).
/// Mirrors Kotlin `MonitorScopeChromeAvoidance`.
public enum MonitorScopeChromeAvoidance {
    /// The clear centre nearest `center`, among the centres `clamp` keeps inside the movement
    /// bounds. `clamp` treats each axis on its own. When chrome leaves no clear centre the
    /// clamped centre stands, so a panel never disappears.
    public static func resolve(
        _ center: MonitorScopePoint, width: Double, height: Double, bottomExtent: Double = 0,
        avoiding obstacles: [MonitorRect], gap: Double,
        clamp: (MonitorScopePoint) -> MonitorScopePoint
    ) -> MonitorScopePoint {
        let start = clamp(center)
        let blocked = obstacles.filter { $0.width > 0 && $0.height > 0 }.map {
            MonitorRect(x: $0.x - gap, y: $0.y - gap, width: $0.width + 2 * gap, height: $0.height + 2 * gap)
        }
        guard !blocked.isEmpty else { return start }
        let tolerance = 0.001
        func clear(_ point: MonitorScopePoint) -> Bool {
            let left = point.x - width / 2, right = point.x + width / 2
            let top = point.y - height / 2, bottom = point.y + height / 2 + bottomExtent
            return !blocked.contains {
                left < $0.maxX - tolerance && right > $0.x + tolerance
                    && top < $0.maxY - tolerance && bottom > $0.y + tolerance
            }
        }
        if clear(start) { return start }
        // The nearest clear centre lies on the start's own row or column, on a chrome edge or at
        // a corner where two edges meet, the movement bounds included.
        let far = 1e9
        var xs = [start.x, clamp(.init(x: -far, y: start.y)).x, clamp(.init(x: far, y: start.y)).x]
        var ys = [start.y, clamp(.init(x: start.x, y: -far)).y, clamp(.init(x: start.x, y: far)).y]
        for rect in blocked {
            xs += [rect.x - width / 2, rect.maxX + width / 2]
            ys += [rect.y - height / 2 - bottomExtent, rect.maxY + height / 2]
        }
        var best: MonitorScopePoint?
        var nearest = Double.infinity
        for x in xs {
            for y in ys {
                let candidate = clamp(.init(x: x, y: y))
                let dx = candidate.x - start.x, dy = candidate.y - start.y
                let distance = dx * dx + dy * dy
                if distance < nearest, clear(candidate) { best = candidate; nearest = distance }
            }
        }
        return best ?? start
    }
}
