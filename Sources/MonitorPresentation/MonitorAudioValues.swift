import Foundation

public enum MonitorAudioOrientation: String, CaseIterable, Codable, Sendable {
    case vertical = "Vertical"
    case horizontal = "Horizontal"
}

public enum MonitorAudioReadout {
    public static let floorDB = -60.0
    public static func fraction(_ db: Double) -> Double {
        guard db.isFinite else { return 0 }
        return min(1, max(0, (db - floorDB) / -floorDB))
    }
    public static func label(_ db: Double) -> String {
        guard db.isFinite, db > floorDB + 0.5 else { return "−∞" }
        return String(format: "%.0f", min(0, db))
    }
}
