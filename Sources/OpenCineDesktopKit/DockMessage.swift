import Foundation

public struct WindowFrame: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

extension WindowFrame {
    /// The height of the strip along the top edge that must stay on a screen: the title bar, which
    /// holds the tabs and is where the window is dragged.
    public static let titleBarHeight = 44.0

    /// The frame to open at, given the visible frames of the attached screens (AppKit coordinates,
    /// origin at the bottom left). Kept while its title bar lies on one screen, at least 100 points
    /// wide; clipped to that screen when larger than it, keeping the top edge. Otherwise a
    /// default-sized frame (no larger than the screen) centred on the first screen. With no screens
    /// known, `self`.
    public func fitted(onto screens: [WindowFrame], defaultWidth: Double, defaultHeight: Double)
        -> WindowFrame
    {
        guard let main = screens.first else { return self }
        let top = y + height
        let titleBarBottom = top - Self.titleBarHeight
        let home = screens.first { screen in
            let overlapWidth = min(x + width, screen.x + screen.width) - max(x, screen.x)
            return overlapWidth >= 100 && titleBarBottom >= screen.y && top <= screen.y + screen.height
        }
        if let home {
            var kept = self
            if kept.width > home.width {
                kept.width = home.width
                kept.x = home.x
            }
            if kept.height > home.height {
                kept.height = top - home.y
                kept.y = home.y
            }
            return kept
        }
        let fittedWidth = min(defaultWidth, main.width)
        let fittedHeight = min(defaultHeight, main.height)
        return WindowFrame(
            x: main.x + (main.width - fittedWidth) / 2, y: main.y + (main.height - fittedHeight) / 2,
            width: fittedWidth, height: fittedHeight)
    }
}

/// One camera tab as every module's tab bar draws it.
public struct DockTab: Codable, Hashable, Sendable {
    public enum State: Codable, Hashable, Sendable {
        case idle
        case connecting
        case live
        case failed
        /// Not running: the tab offers a restart.
        case stopped
    }

    public var id: String
    public var displayName: String
    public var state: State
    /// The module app's bundle identifier, so the window that is left can hand keyboard focus to the
    /// one that comes in (macOS lets an app take focus only when the active one yields it).
    public var bundleID: String?

    public init(id: String, displayName: String, state: State, bundleID: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.state = state
        self.bundleID = bundleID
    }
}

/// A line at the trailing end of the tab bar, such as the driver needing approval.
public struct DockNotice: Codable, Hashable, Sendable {
    /// The System Settings page where the owner turns the camera driver on.
    public static let driverSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    public var text: String
    /// Clicking it opens the system settings where the camera driver is turned on.
    public var opensDriverSettings: Bool

    public init(text: String, opensDriverSettings: Bool) {
        self.text = text
        self.opensDriverSettings = opensDriverSettings
    }
}

public enum ModuleStatus: Codable, Equatable, Sendable {
    case idle
    case connecting
    case live(cameraName: String?)
    case failed(String)
}

/// From the dock to a module.
public enum DockMessage: Codable, Hashable, Sendable {
    /// Bring the window in front at `frame`; the module answers `shown` once it is on screen.
    case show(frame: WindowFrame)
    /// Keep the hidden window at `frame`, without bringing it in.
    case place(frame: WindowFrame)
    case hide
    case quit
    /// What the tab bar shows: every tab, the selected one and an optional notice.
    case tabs([DockTab], selectedID: String?, notice: DockNotice?)
}

/// From a module to the dock.
public enum ModuleMessage: Codable, Equatable, Sendable {
    case ready(moduleID: String)
    case status(ModuleStatus)
    /// The owner clicked a tab in this module's tab bar.
    case selectTab(id: String)
    /// The visible window moved or resized; `final` once the change has settled.
    case windowFrame(WindowFrame, final: Bool)
    /// The window is on screen after a `show`.
    case shown
    /// The owner clicked the window's close button.
    case closeRequested
}

public enum LengthPrefixedJSONError: Error, Equatable, Sendable {
    case messageTooLarge
}

/// Four-byte big-endian length, then JSON. Reads tolerate messages split at any byte.
public enum LengthPrefixedJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let body = try JSONEncoder().encode(value)
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// Removes and decodes every complete message in `buffer`, leaving any partial one.
    public static func decodeAll<T: Decodable>(
        _ buffer: inout Data, maxMessageBytes: Int = 64 * 1024
    ) throws -> [T] {
        var messages: [T] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start..<(start + 4)].reduce(0) { $0 << 8 | Int($1) }
            guard length <= maxMessageBytes else { throw LengthPrefixedJSONError.messageTooLarge }
            guard buffer.count >= 4 + length else { break }
            messages.append(
                try JSONDecoder().decode(T.self, from: buffer[(start + 4)..<(start + 4 + length)]))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return messages
    }
}
