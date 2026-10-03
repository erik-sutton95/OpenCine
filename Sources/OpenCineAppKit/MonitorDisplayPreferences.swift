import Foundation

/// DISP 1 Live / DISP 2 Clean. Command (DISP 3) is not in this build.
public enum MonitorDisplayMode: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case live
    case clean

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .live: "Live"
        case .clean: "Clean"
        }
    }

    public var settingsTitle: String {
        switch self {
        case .live: "DISP 1 · Live"
        case .clean: "DISP 2 · Clean"
        }
    }

    public var settingsCaption: String {
        switch self {
        case .live:
            "The full monitor. Set what it shows in Edit view."
        case .clean:
            "A stripped-back image. Same elements as DISP 1 \u{2014} status, tool and capture bars start off. Pin which view assists stay on."
        }
    }
}

/// Per-display visibility for live and clean monitor layouts.
public struct MonitorDisplayChrome: Equatable, Codable, Sendable {
    /// Containers first, then rail / on-feed chrome, then status-bar cells last so
    /// Edit-view badges keep the big boxes' preferred corners.
    public enum Section: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
        case statusBar
        case toolBar
        case cameraValues
        case lockButton
        case batteries
        case railRecord
        case railMedia
        case railSettings
        case zoomChip
        case gimbalStick
        case focusBox
        case recReadout
        case timecode
        case format
        case color
        case storage
        case fps

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .statusBar: "Status Bar"
            case .toolBar: "Tool Bar"
            case .cameraValues: "Camera Values"
            case .lockButton: "Lock Button"
            case .batteries: "Batteries"
            case .railRecord: "Record"
            case .railMedia: "Media"
            case .railSettings: "Settings"
            case .zoomChip: "Zoom Chip"
            case .gimbalStick: "Gimbal Stick"
            case .focusBox: "Face Box"
            case .recReadout: "REC"
            case .timecode: "Timecode"
            case .format: "Format"
            case .color: "Color"
            case .storage: "Storage"
            case .fps: "FPS"
            }
        }
    }

    public var statusBar = true
    public var toolBar = true
    public var cameraValues = true
    public var lockButton = true
    public var batteries = true
    public var recReadout = true
    public var timecode = true
    public var format = true
    public var color = true
    public var storage = true
    public var fps = true
    public var railRecord = true
    public var railMedia = true
    public var railSettings = true
    public var zoomChip = true
    public var gimbalStick = true
    public var focusBox = true

    public init(
        statusBar: Bool = true,
        toolBar: Bool = true,
        cameraValues: Bool = true,
        lockButton: Bool = true,
        batteries: Bool = true,
        recReadout: Bool = true,
        timecode: Bool = true,
        format: Bool = true,
        color: Bool = true,
        storage: Bool = true,
        fps: Bool = true,
        railRecord: Bool = true,
        railMedia: Bool = true,
        railSettings: Bool = true,
        zoomChip: Bool = true,
        gimbalStick: Bool = true,
        focusBox: Bool = true,
    ) {
        self.statusBar = statusBar
        self.toolBar = toolBar
        self.cameraValues = cameraValues
        self.lockButton = lockButton
        self.batteries = batteries
        self.recReadout = recReadout
        self.timecode = timecode
        self.format = format
        self.color = color
        self.storage = storage
        self.fps = fps
        self.railRecord = railRecord
        self.railMedia = railMedia
        self.railSettings = railSettings
        self.zoomChip = zoomChip
        self.gimbalStick = gimbalStick
        self.focusBox = focusBox
    }

    public static let liveDefaults = MonitorDisplayChrome()

    public static let cleanDefaults = MonitorDisplayChrome(
        statusBar: false,
        toolBar: false,
        cameraValues: false,
        lockButton: false,
        batteries: true,
        recReadout: true,
        timecode: true,
        format: true,
        color: true,
        storage: true,
        fps: true,
        railRecord: true,
        railMedia: true,
        railSettings: true,
        zoomChip: true,
        gimbalStick: true,
        focusBox: true
    )

    public func isVisible(_ section: Section) -> Bool {
        switch section {
        case .statusBar: statusBar
        case .toolBar: toolBar
        case .cameraValues: cameraValues
        case .lockButton: lockButton
        case .batteries: batteries
        case .railRecord: railRecord
        case .railMedia: railMedia
        case .railSettings: railSettings
        case .zoomChip: zoomChip
        case .gimbalStick: gimbalStick
        case .focusBox: focusBox
        case .recReadout: recReadout
        case .timecode: timecode
        case .format: format
        case .color: color
        case .storage: storage
        case .fps: fps
        }
    }

    public mutating func toggle(_ section: Section) {
        switch section {
        case .statusBar: statusBar.toggle()
        case .toolBar: toolBar.toggle()
        case .cameraValues: cameraValues.toggle()
        case .lockButton: lockButton.toggle()
        case .batteries: batteries.toggle()
        case .railRecord: railRecord.toggle()
        case .railMedia: railMedia.toggle()
        case .railSettings: railSettings.toggle()
        case .zoomChip: zoomChip.toggle()
        case .gimbalStick: gimbalStick.toggle()
        case .focusBox: focusBox.toggle()
        case .recReadout: recReadout.toggle()
        case .timecode: timecode.toggle()
        case .format: format.toggle()
        case .color: color.toggle()
        case .storage: storage.toggle()
        case .fps: fps.toggle()
        }
    }

    /// Live and clean offer the same list with different defaults.
    public static func isConfigurable(_ section: Section, in mode: MonitorDisplayMode) -> Bool {
        _ = section
        _ = mode
        return true
    }

    public static func configurableSections(in mode: MonitorDisplayMode) -> [Section] {
        Section.allCases.filter { isConfigurable($0, in: mode) }
    }
}

/// Saved live/clean layouts under app-supplied legacy keys. Reading performs no writes.
/// Apple retains whole-value fallback for incomplete or malformed Codable data.
public final class MonitorDisplayPreferences: @unchecked Sendable {
    public struct Keys: Sendable {
        public let live: String
        public let clean: String

        public init(live: String, clean: String) {
            precondition(!live.isEmpty && !clean.isEmpty && live != clean)
            self.live = live
            self.clean = clean
        }
    }

    private let storage: UserDefaults
    private let keys: Keys

    public init(storage: UserDefaults, keys: Keys) {
        self.storage = storage
        self.keys = keys
    }

    public var live: MonitorDisplayChrome {
        get { read(keys.live) ?? .liveDefaults }
        set { write(newValue, key: keys.live) }
    }

    public var clean: MonitorDisplayChrome {
        get { read(keys.clean) ?? .cleanDefaults }
        set { write(newValue, key: keys.clean) }
    }

    private func read(_ key: String) -> MonitorDisplayChrome? {
        guard let data = storage.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(MonitorDisplayChrome.self, from: data)
    }

    private func write(_ value: MonitorDisplayChrome, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            storage.set(data, forKey: key)
        }
    }
}
