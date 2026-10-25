import Foundation

/// DISP 1 Live, DISP 2 Clean and DISP 3 Command. A source declares which it offers
/// (`MonitorOperatorSessionModel.declare(modes:)`): Command only where the source supplies a
/// camera dashboard in place of the picture.
public enum MonitorDisplayMode: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case live
    case clean
    case command

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .live: "Live"
        case .clean: "Clean"
        case .command: "Command"
        }
    }

    public var settingsTitle: String {
        switch self {
        case .live: "DISP 1 · Live"
        case .clean: "DISP 2 · Clean"
        case .command: "DISP 3 · Command"
        }
    }

    public var settingsCaption: String {
        switch self {
        case .live:
            "The full monitor. Set what it shows in Edit view."
        case .clean:
            "A stripped-back image. Same elements as DISP 1. Status, tool and capture bars start off. Pin which view assists stay on."
        case .command:
            "The camera dashboard in place of the picture. Only the rail is yours to arrange."
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
        case codec
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
            case .codec: "Codec"
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
    /// The recording codec chip, for sources that report one apart from the format.
    public var codec = true
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
        codec: Bool = true,
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
        self.codec = codec
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

    private enum CodingKeys: String, CodingKey {
        case statusBar, toolBar, cameraValues, lockButton, batteries, recReadout, timecode, format,
            codec, color, storage, fps, railRecord, railMedia, railSettings, zoomChip, gimbalStick,
            focusBox
    }

    /// Every pre-codec key is required (an incomplete blob keeps the whole-value fallback);
    /// `codec` arrived later, so a layout saved before it shows the codec chip.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        statusBar = try c.decode(Bool.self, forKey: .statusBar)
        toolBar = try c.decode(Bool.self, forKey: .toolBar)
        cameraValues = try c.decode(Bool.self, forKey: .cameraValues)
        lockButton = try c.decode(Bool.self, forKey: .lockButton)
        batteries = try c.decode(Bool.self, forKey: .batteries)
        recReadout = try c.decode(Bool.self, forKey: .recReadout)
        timecode = try c.decode(Bool.self, forKey: .timecode)
        format = try c.decode(Bool.self, forKey: .format)
        codec = try c.decodeIfPresent(Bool.self, forKey: .codec) ?? true
        color = try c.decode(Bool.self, forKey: .color)
        storage = try c.decode(Bool.self, forKey: .storage)
        fps = try c.decode(Bool.self, forKey: .fps)
        railRecord = try c.decode(Bool.self, forKey: .railRecord)
        railMedia = try c.decode(Bool.self, forKey: .railMedia)
        railSettings = try c.decode(Bool.self, forKey: .railSettings)
        zoomChip = try c.decode(Bool.self, forKey: .zoomChip)
        gimbalStick = try c.decode(Bool.self, forKey: .gimbalStick)
        focusBox = try c.decode(Bool.self, forKey: .focusBox)
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
        case .codec: codec
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
        case .codec: codec.toggle()
        case .color: color.toggle()
        case .storage: storage.toggle()
        case .fps: fps.toggle()
        }
    }

    /// Live and clean offer the same list with different defaults. Command has no picture, so
    /// only the rail cluster is the operator's to arrange there; the rest keeps its stock value.
    public static func isConfigurable(_ section: Section, in mode: MonitorDisplayMode) -> Bool {
        switch mode {
        case .live, .clean: true
        case .command:
            [.lockButton, .batteries, .railRecord, .railMedia, .railSettings].contains(section)
        }
    }

    /// The stock layout of `mode`.
    public static func defaults(for mode: MonitorDisplayMode) -> MonitorDisplayChrome {
        mode == .clean ? cleanDefaults : liveDefaults
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
        /// Present only for an app whose sources offer DISP 3.
        public let command: String?

        public init(live: String, clean: String, command: String? = nil) {
            precondition(!live.isEmpty && !clean.isEmpty && live != clean)
            precondition(command.map { !$0.isEmpty && $0 != live && $0 != clean } ?? true)
            self.live = live
            self.clean = clean
            self.command = command
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

    /// DISP 3's rail layout; stock (and not stored) when the app has no command key.
    public var command: MonitorDisplayChrome {
        get { keys.command.flatMap(read) ?? .liveDefaults }
        set { if let key = keys.command { write(newValue, key: key) } }
    }

    /// Whether `mode` has a stored layout, for an app that seeds one from an older store once.
    public func hasStoredLayout(for mode: MonitorDisplayMode) -> Bool {
        let key: String? =
            switch mode {
            case .live: keys.live
            case .clean: keys.clean
            case .command: keys.command
            }
        return key.map { storage.data(forKey: $0) != nil } ?? false
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
