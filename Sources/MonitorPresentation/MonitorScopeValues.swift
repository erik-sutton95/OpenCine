import Foundation

public enum MonitorWaveformMode: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case luma = "Luma"
    case rgb = "RGB"
    public var id: String { rawValue }
}

public enum MonitorParadeMode: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case rgb = "RGB"
    case yrgb = "YRGB"
    public var id: String { rawValue }
    public var laneCount: Int { self == .yrgb ? 4 : 3 }
}

public enum MonitorVectorscopeZoom: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case x1 = "1x"
    case x2 = "2x"
    case x4 = "4x"
    public var id: String { rawValue }
    public var gain: Double {
        switch self { case .x1: 1; case .x2: 2; case .x4: 4 }
    }
}

public struct MonitorScopeGuides: Codable, Equatable, Sendable {
    public var clip: Bool
    public var crush: Bool
    public var middle: Bool
    public static let `default` = Self()
    public init(clip: Bool = true, crush: Bool = true, middle: Bool = true) {
        self.clip = clip; self.crush = crush; self.middle = middle
    }
}
