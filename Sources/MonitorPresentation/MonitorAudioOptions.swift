import Foundation

public struct MonitorAudioStoredCenter: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}
public struct MonitorAudioOptions: Codable, Equatable, Sendable {
    public var orientation: MonitorAudioOrientation
    public var showsDB: Bool
    public var landscapeCenter: MonitorAudioStoredCenter?
    public var portraitCenter: MonitorAudioStoredCenter?
    public init(orientation: MonitorAudioOrientation = .vertical, showsDB: Bool = false,
        landscapeCenter: MonitorAudioStoredCenter? = nil, portraitCenter: MonitorAudioStoredCenter? = nil) {
        self.orientation = orientation; self.showsDB = showsDB
        self.landscapeCenter = landscapeCenter; self.portraitCenter = portraitCenter
    }
}
public struct MonitorFalseColorReferencePositions: Codable, Equatable, Sendable {
    public struct Center: Codable, Equatable, Sendable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }
    public var landscape: Center?
    public var portrait: Center?
    public init(landscape: Center? = nil, portrait: Center? = nil) {
        self.landscape = landscape; self.portrait = portrait
    }
}
