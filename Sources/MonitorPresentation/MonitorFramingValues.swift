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

/// One safe area drawn inside every frame line.
public enum MonitorGuideSafeAreaKind: String, CaseIterable, Identifiable, Sendable {
    case action
    case title

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .action: "Action safe"
        case .title: "Title safe"
        }
    }
    public var help: String {
        switch self {
        case .action:
            "A dashed line inside each frame line. Keep the action inside it to leave room to stabilize or reframe."
        case .title: "A dotted line inside each frame line for text and graphics."
        }
    }
}

/// A safe area that is switched on, with its share of the frame line.
public struct MonitorGuideSafeArea: Equatable, Sendable, Identifiable {
    public let kind: MonitorGuideSafeAreaKind
    public let percent: Int
    public var id: MonitorGuideSafeAreaKind { kind }
    public init(kind: MonitorGuideSafeAreaKind, percent: Int) { self.kind = kind; self.percent = percent }
}

/// Action safe and title safe lines inside each drawn frame line. Each is a centred share of the
/// frame line's width and height, so 90% leaves 5% of the frame clear on every side. Both start
/// off at 90% and 80%. Mirrors Kotlin `MonitorGuideSafeAreas`.
public struct MonitorGuideSafeAreas: Codable, Equatable, Sendable {
    public static let percentRange: ClosedRange<Int> = 50...99
    public static let standardActionPercent = 90
    public static let standardTitlePercent = 80
    public static let standard = MonitorGuideSafeAreas()
    public static let sizeHelp = "Share of the frame line's width and height, from 50% to 99%."

    public private(set) var actionSafe: Bool
    public private(set) var actionPercent: Int
    public private(set) var titleSafe: Bool
    public private(set) var titlePercent: Int

    public init(
        actionSafe: Bool = false, actionPercent: Int = standardActionPercent,
        titleSafe: Bool = false, titlePercent: Int = standardTitlePercent
    ) {
        self.actionSafe = actionSafe; self.actionPercent = Self.clamped(actionPercent)
        self.titleSafe = titleSafe; self.titlePercent = Self.clamped(titlePercent)
    }

    /// Saved values outside the range clamp; a missing field keeps its default.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            actionSafe: try values.decodeIfPresent(Bool.self, forKey: .actionSafe) ?? false,
            actionPercent: try values.decodeIfPresent(Int.self, forKey: .actionPercent)
                ?? Self.standardActionPercent,
            titleSafe: try values.decodeIfPresent(Bool.self, forKey: .titleSafe) ?? false,
            titlePercent: try values.decodeIfPresent(Int.self, forKey: .titlePercent)
                ?? Self.standardTitlePercent)
    }

    public func isOn(_ kind: MonitorGuideSafeAreaKind) -> Bool {
        kind == .action ? actionSafe : titleSafe
    }

    public func percent(_ kind: MonitorGuideSafeAreaKind) -> Int {
        kind == .action ? actionPercent : titlePercent
    }

    public mutating func set(_ kind: MonitorGuideSafeAreaKind, on: Bool) {
        if kind == .action { actionSafe = on } else { titleSafe = on }
    }

    public mutating func set(_ kind: MonitorGuideSafeAreaKind, percent: Int) {
        if kind == .action { actionPercent = Self.clamped(percent) } else { titlePercent = Self.clamped(percent) }
    }

    /// The safe areas to draw, action safe first.
    public var drawn: [MonitorGuideSafeArea] {
        MonitorGuideSafeAreaKind.allCases.filter(isOn).map { MonitorGuideSafeArea(kind: $0, percent: percent($0)) }
    }

    public static func label(_ percent: Int) -> String { "\(percent)%" }

    public static func clamped(_ percent: Int) -> Int {
        min(max(percent, percentRange.lowerBound), percentRange.upperBound)
    }

    /// The centred `percent` share of `frame`'s width and height.
    public static func inset(_ frame: MonitorRect, percent: Int) -> MonitorRect {
        let share = Double(clamped(percent)) / 100
        let width = frame.width * share
        let height = frame.height * share
        return MonitorRect(
            x: frame.x + (frame.width - width) / 2, y: frame.y + (frame.height - height) / 2,
            width: width, height: height)
    }
}
