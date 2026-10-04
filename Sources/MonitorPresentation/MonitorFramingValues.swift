import Foundation

public enum MonitorGuideFamily: String, CaseIterable, Codable, Sendable, Identifiable {
    case film = "Film"
    case social = "Social"
    public var id: String { rawValue }
}

public enum MonitorGuideAspect: String, CaseIterable, Identifiable, Codable, Sendable {
    case cinema276 = "2.76:1"
    case cinema = "2.39:1"
    case cinema235 = "2.35:1"
    case twoK = "2.00:1"
    case wide = "1.85:1"
    case hd = "16:9"
    case euro = "1.66:1"
    case imax = "1.43:1"
    case academy = "4:3"
    case vertical = "9:16"
    case social = "4:5"
    case square = "1:1"
    case portrait = "2:3"
    case feed = "1.91:1"

    public var id: String { rawValue }

    public var aspectRatio: Double {
        let parts = rawValue.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0 else { return 1 }
        return parts[0] / parts[1]
    }

    public static func ratios(for family: MonitorGuideFamily) -> [MonitorGuideAspect] {
        switch family {
        case .film: [.cinema276, .cinema, .cinema235, .twoK, .wide, .hd, .euro, .imax, .academy]
        case .social: [.vertical, .social, .square, .portrait, .hd, .feed]
        }
    }
}

/// Which selected frame area stays clear when the optional guide mask is enabled.
public enum MonitorGuideMaskPolicy: Equatable, Sendable {
    /// Keep the union of the actual selected frame rectangles clear.
    case union
    /// Keep their bounding rectangle clear, including space between crossing frames.
    case envelope
}

public enum MonitorGridOption: String, CaseIterable, Identifiable, Sendable {
    case thirds = "Thirds"
    case phi = "Phi Grid"
    case diagonal = "Diagonal"

    public var id: String { rawValue }
}
