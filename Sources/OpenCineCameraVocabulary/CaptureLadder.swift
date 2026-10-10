import Foundation

/// One camera setting picked from a list of the camera's own labels, in camera order: the
/// settings with no typed meaning (focus area, codec, drive, picture control). Typed settings
/// (ISO, shutter, iris, white balance) stay on the core capability model.
public struct CaptureLadder: Equatable, Sendable {
    /// The camera's current label. Nil when it has not reported one.
    public let current: String?
    public let values: [String]
    /// Values the drum marks (native base ISOs).
    public let marked: Set<String>
    /// Why this drum cannot change now. Nil when it can.
    public let lock: CaptureLock?

    public init(
        current: String?, values: [String], marked: Set<String> = [], lock: CaptureLock? = nil
    ) {
        self.current = current
        self.values = values
        self.marked = marked
        self.lock = lock
    }
}

/// Why a setting cannot change now. Recording and camera control freeze the whole sheet.
/// Auto and exposure program freeze only the drum, so the operator can still leave Auto.
public enum CaptureLock: Equatable, Sendable, Hashable {
    case recording
    case cameraControl
    case exposureProgram
    case auto

    public var freezesSheet: Bool {
        self == .recording || self == .cameraControl
    }
}

/// A white balance fine-tune position in grid cells. `amberBlue` nil is a green/magenta-only tune.
public struct CaptureTint: Equatable, Sendable {
    public let greenMagenta: Int
    public let amberBlue: Int?
    public let range: ClosedRange<Int>

    public init(greenMagenta: Int, amberBlue: Int?, range: ClosedRange<Int>) {
        self.greenMagenta = greenMagenta
        self.amberBlue = amberBlue
        self.range = range
    }
}
