import Foundation

/// A reading area that uses the free monitor canvas while keeping visible camera chrome clear.
public enum TeleprompterOverlayLayout {
    /// Finds the largest unobstructed rectangle between status and camera values, including letterbox space.
    public static func frame(
        layout: FieldMonitorLayout, safeArea: MonitorSafeArea,
        shown: MonitorScopeChrome, motionCluster: Bool, extraObstacles: [MonitorRect] = []
    ) -> MonitorRect {
        let gap = 8.0
        let left = max(0, safeArea.leading) + 12
        let right = layout.viewport.width - max(0, safeArea.trailing) - 12
        let top = max(
            max(0, safeArea.top) + 12, shown.contains(.status) ? layout.status.maxY + gap : 0)
        let bottom = min(
            layout.viewport.height - max(0, safeArea.bottom) - 12,
            shown.contains(.values) ? layout.values.y - gap : layout.viewport.height)
        guard right > left, bottom > top else { return .init() }
        let obstacles =
            (layout.scopeObstacles(shown, motionCluster: motionCluster) + extraObstacles)
            .filter {
                $0.width > 0 && $0.height > 0 && $0.maxX + gap > left && $0.x - gap < right
                    && $0.maxY + gap > top && $0.y - gap < bottom
            }
            .sorted { $0.x < $1.x }
        let tops = [top] + obstacles.map { $0.maxY + gap }.filter { $0 > top && $0 < bottom }
        let bottoms = [bottom] + obstacles.map { $0.y - gap }.filter { $0 > top && $0 < bottom }
        let center = MonitorScopePoint(x: (left + right) / 2, y: (top + bottom) / 2)
        var best = MonitorRect()
        var bestDistance = Double.infinity
        func consider(_ x: Double, _ end: Double, _ y: Double, _ floor: Double) {
            guard end > x else { return }
            let candidate = MonitorRect(x: x, y: y, width: end - x, height: floor - y)
            let distance = pow(candidate.midX - center.x, 2) + pow(candidate.midY - center.y, 2)
            let area = candidate.width * candidate.height
            if area > best.width * best.height
                || (area == best.width * best.height && distance < bestDistance)
            {
                best = candidate
                bestDistance = distance
            }
        }
        // An empty rectangle ends at a canvas or obstacle edge. Scan horizontal bands and
        // the free x intervals in each band, rather than shrinking unrelated dimensions.
        for y in Set(tops).sorted() {
            for floor in Set(bottoms).sorted() where floor > y {
                var start = left
                for obstacle in obstacles where obstacle.y - gap < floor && obstacle.maxY + gap > y
                {
                    consider(start, min(right, obstacle.x - gap), y, floor)
                    start = max(start, obstacle.maxX + gap)
                }
                consider(start, right, y, floor)
            }
        }
        return best
    }
}
