import Foundation
import OpenCineCore

/// An honest measured gauge or percentage projection, supplied independently of relay wire types.
public struct WatchMonitorBattery: Equatable, Sendable {
    public enum Urgency: Equatable, Sendable { case nominal, low, depleted }
    /// Compatibility gauge fields for the original initializer. A fraction reading has no gauge
    /// and reports 0 of 0, so new code reads `reading`.
    public let filledBars: Int
    public let barCount: Int
    public let urgency: Urgency
    public let accessibilityLabel: String
    /// The active presentation reads this common value; fractions have no invented bars.
    public let reading: BatteryReading
    public let exhausted: Bool?

    public init(filledBars: Int, barCount: Int, urgency: Urgency, accessibilityLabel: String) {
        precondition(barCount > 0 && (0...barCount).contains(filledBars))
        self.filledBars = filledBars; self.barCount = barCount
        self.urgency = urgency; self.accessibilityLabel = accessibilityLabel
        reading = .steps(filled: filledBars, of: barCount)
        exhausted = nil
    }

    private init(reading: BatteryReading, exhausted: Bool?, urgency: Urgency, accessibilityLabel: String) {
        self.reading = reading; self.exhausted = exhausted
        self.urgency = urgency; self.accessibilityLabel = accessibilityLabel
        switch reading {
        case .fraction: filledBars = 0; barCount = 0
        case .steps(let filled, let count): filledBars = filled; barCount = count
        }
    }

    /// A fraction prints a percentage; a declared gauge keeps its actual bar count.
    public static func measured(_ reading: BatteryReading?, exhausted: Bool? = nil) -> Self? {
        guard let reading else { return nil }
        let fraction: Double
        let label: String
        switch reading {
        case .fraction(let value):
            guard value.isFinite, (0...1).contains(value) else { return nil }
            fraction = value
            label = "Camera battery \(Int((value * 100).rounded())) percent"
        case .steps(let filled, let count):
            guard count > 0, (0...count).contains(filled) else { return nil }
            fraction = Double(filled) / Double(count)
            label = "Camera battery \(filled) of \(count) bars"
        }
        return Self(reading: reading, exhausted: exhausted,
            urgency: fraction <= 0.2 ? .depleted : fraction <= 0.4 ? .low : .nominal,
            accessibilityLabel: label)
    }

    @available(*, deprecated, message: "Pass the source-declared BatteryReading to measured(_:exhausted:)")
    public static func percentage(_ reported: Int?) -> Self? {
        guard let reported, reported >= 0 else { return nil }
        let filled = reported == 0 ? 0 : min(5, max(1, Int(ceil(Double(min(100, reported)) / 20))))
        return Self(filledBars: filled, barCount: 5,
            urgency: reported <= 20 ? .depleted : reported <= 40 ? .low : .nominal,
            accessibilityLabel: "Camera battery \(reported) percent")
    }
}

/// The complete wrist presentation. Adapters project reports without teaching the view a wire schema.
public struct WatchMonitorPresentation: Equatable, Sendable {
    public let sourceRevision: UInt64?
    public let header: String
    public let headerAccessibility: String?
    public let media: String?
    public let battery: WatchMonitorBattery?
    public let recording: Bool?
    public let photography: Bool?
    public let feedAspectRatio: Double?
    public let canCapture: Bool
    public let placeholder: String?
    public let commandMessage: String?

    public init(sourceRevision: UInt64?, header: String, headerAccessibility: String? = nil,
        media: String?, battery: WatchMonitorBattery?, recording: Bool?, photography: Bool?,
        feedAspectRatio: Double?, canCapture: Bool, placeholder: String?, commandMessage: String?) {
        self.sourceRevision = sourceRevision; self.header = header; self.headerAccessibility = headerAccessibility
        self.media = media; self.battery = battery; self.recording = recording; self.photography = photography
        self.feedAspectRatio = feedAspectRatio; self.canCapture = canCapture
        self.placeholder = placeholder; self.commandMessage = commandMessage
    }

    public var aspectRatio: Double {
        guard let feedAspectRatio, feedAspectRatio.isFinite, feedAspectRatio > 0 else { return 16 / 9 }
        return feedAspectRatio
    }

    public func admits(_ action: WatchMonitorAction) -> Bool {
        guard let sourceRevision, canCapture, sourceRevision == action.sourceRevision else { return false }
        switch action.intent {
        case .capture: return photography == true
        case .record(let target): return photography == false && recording == !target
        }
    }
}

public struct WatchMonitorAction: Equatable, Sendable {
    public enum Intent: Equatable, Sendable { case capture, record(Bool) }
    public let sourceRevision: UInt64?
    public let intent: Intent
    public init(sourceRevision: UInt64?, intent: Intent) {
        self.sourceRevision = sourceRevision; self.intent = intent
    }
}

/// Crown magnification and pan share one source lifetime; interrupted movement never becomes saved pan.
public struct WatchPreviewInspection: Equatable, Sendable {
    public private(set) var zoom: Double = 1
    public private(set) var panX: Double = 0
    public private(set) var panY: Double = 0
    private var savedX: Double = 0
    private var savedY: Double = 0
    private var originX: Double?
    private var originY: Double?
    private var sourceRevision: UInt64?
    private var cancelled = false
    public static let maximumZoom: Double = 4
    public init() {}

    public mutating func synchronize(sourceRevision: UInt64?) {
        guard self.sourceRevision != sourceRevision else { return }
        self.sourceRevision = sourceRevision
        zoom = 1; savedX = 0; savedY = 0
        interruptPan()
    }

    public mutating func setZoom(_ value: Double) {
        guard value.isFinite else { return }
        zoom = min(Self.maximumZoom, max(1, value))
        if zoom == 1 { savedX = 0; savedY = 0; interruptPan() }
    }

    public mutating func updatePan(x: Double, y: Double) {
        guard !cancelled, zoom > 1, x.isFinite, y.isFinite else { return }
        if originX == nil { originX = savedX; originY = savedY }
        panX = (originX ?? savedX) + x; panY = (originY ?? savedY) + y
    }

    public mutating func endPan(width: Double, height: Double) {
        defer { endPointer() }
        guard !cancelled, originX != nil else { return }
        let pan = clampedPan(width: width, height: height)
        savedX = pan.x; savedY = pan.y; panX = pan.x; panY = pan.y
    }

    public mutating func interruptPan(pointerActive: Bool = false) {
        cancelled = cancelled || originX != nil || pointerActive
        originX = nil; originY = nil; panX = savedX; panY = savedY
    }

    public mutating func endPointer() {
        originX = nil; originY = nil; cancelled = false
        panX = savedX; panY = savedY
    }

    public func clampedPan(width: Double, height: Double) -> (x: Double, y: Double) {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return (0, 0) }
        let limitX = max(0, width * (zoom - 1) / 2)
        let limitY = max(0, height * (zoom - 1) / 2)
        return (min(limitX, max(-limitX, panX)), min(limitY, max(-limitY, panY)))
    }
}
