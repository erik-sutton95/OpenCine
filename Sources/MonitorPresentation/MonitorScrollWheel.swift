import Foundation

// The scroll wheel on a dial setting in a desktop window (spec
// 2026-11-25-desktop-mac-sized-ui-and-scroll-dials-design.md). Mac only, so no Kotlin twin.

/// Turns scroll-wheel and trackpad input into whole steps through a dial's values. A mouse detent
/// is one step; trackpad travel adds up and makes a step every `trackpadDistance` points.
/// Scrolling down or right is the next value, up or left the previous one, as the dial's own drag.
public struct MonitorScrollAccumulator: Equatable, Sendable {
    public enum Device: Equatable, Sendable {
        /// A wheel that clicks in detents (a discrete scroll).
        case mouse
        /// A trackpad or a free-spinning wheel (a continuous scroll).
        case trackpad
    }

    /// Trackpad travel, in points, that makes one step.
    public var trackpadDistance: Double
    private var travel = 0.0

    public init(trackpadDistance: Double = 24) {
        self.trackpadDistance = trackpadDistance
    }

    /// Steps for one scroll event, positive toward the next value. `dx` and `dy` are UIKit's
    /// scroll translation, the content's movement: scrolling down moves it up (negative `dy`). The
    /// larger axis decides.
    public mutating func steps(dx: Double, dy: Double, device: Device) -> Int {
        let x = dx.isFinite ? dx : 0
        let y = dy.isFinite ? dy : 0
        let delta = abs(y) >= abs(x) ? -y : -x
        guard delta != 0 else { return 0 }
        switch device {
        case .mouse:
            return delta > 0 ? 1 : -1
        case .trackpad:
            // A reversal starts over instead of first unwinding what the other way left.
            if travel != 0, (travel > 0) != (delta > 0) { travel = 0 }
            travel += delta
            let distance = trackpadDistance > 0 ? trackpadDistance : 24
            let whole = Int(travel / distance)
            travel -= Double(whole) * distance
            return whole
        }
    }

    /// The value index after one scroll event from `index` in a list of `count`, kept inside the
    /// list; nil when it does not change. Pushing past an end stores nothing, so turning back moves
    /// at once.
    public mutating func index(from index: Int, count: Int, dx: Double, dy: Double, device: Device) -> Int? {
        guard count > 0 else { return nil }
        let base = min(max(0, index), count - 1)
        let steps = steps(dx: dx, dy: dy, device: device)
        guard steps != 0 else { return nil }
        let target = base + steps
        let clamped = min(max(0, target), count - 1)
        if clamped != target { travel = 0 }
        return clamped == base ? nil : clamped
    }

    public mutating func reset() { travel = 0 }
}

/// Coalesces a fast run of value changes into few camera writes: the first goes at once, then at
/// most one per `interval`, always the latest value. Times are seconds on any one clock.
public struct MonitorWriteCoalescer<Value: Equatable & Sendable>: Sendable {
    public enum Action: Equatable, Sendable {
        case write(Value)
        /// Held; `due(at:)` hands it over from `until` on.
        case wait(until: Double)
    }

    public let interval: Double
    /// The latest value waiting for its turn.
    public private(set) var pending: Value?
    private var lastWrite: (value: Value, at: Double)?

    public init(interval: Double) {
        self.interval = interval
    }

    /// When the held value is due, or nil with nothing held.
    public var dueAt: Double? {
        guard pending != nil, let lastWrite else { return nil }
        return lastWrite.at + interval
    }

    /// A new value: written now when nothing was written within `interval`, else held as the
    /// latest. A value equal to the last one written replaces nothing to send.
    public mutating func submit(_ value: Value, at now: Double) -> Action {
        if let lastWrite, now - lastWrite.at < interval {
            pending = value == lastWrite.value ? nil : value
            return .wait(until: lastWrite.at + interval)
        }
        lastWrite = (value, now)
        pending = nil
        return .write(value)
    }

    /// The held value once its time has come; it then counts as written.
    public mutating func due(at now: Double) -> Value? {
        guard let pending, let dueAt, now >= dueAt else { return nil }
        lastWrite = (pending, now)
        self.pending = nil
        return pending
    }
}

/// The wheel on one dial setting after another: steps through each setting's values and
/// coalesces its camera writes. A spin steps from the last value it chose while that is younger
/// than `hold`, since the camera's report lags the spin; after that, or when the value left the
/// list, it steps from the reported value again (a write the camera never answered is not kept).
public struct MonitorWheelDial<Key: Hashable> {
    /// One scroll event's outcome: the value chosen for `key`, written now (`write`) or held
    /// until `due`.
    public struct Turn: Equatable {
        public let key: Key
        public let value: String
        public let write: Bool
        public let due: Double?

        public init(key: Key, value: String, write: Bool, due: Double?) {
            self.key = key
            self.value = value
            self.write = write
            self.due = due
        }
    }

    public let interval: Double
    public let hold: Double
    private var scroll: MonitorScrollAccumulator
    private var lastKey: Key?
    private var chosen: [Key: (value: String, at: Double)] = [:]
    private var writes: [Key: MonitorWriteCoalescer<String>] = [:]

    public init(interval: Double = 0.12, hold: Double = 1.0, trackpadDistance: Double = 24) {
        self.interval = interval
        self.hold = hold
        scroll = MonitorScrollAccumulator(trackpadDistance: trackpadDistance)
    }

    /// One scroll event on `key`, whose values are `options` and whose reported value sits at
    /// `reported`. Nil when the value does not change.
    public mutating func turn(
        key: Key, options: [String], reported: Int, dx: Double, dy: Double,
        device: MonitorScrollAccumulator.Device, at now: Double
    ) -> Turn? {
        if key != lastKey {
            scroll.reset()
            lastKey = key
        }
        var base = reported
        if let last = chosen[key], now - last.at < hold, let index = options.firstIndex(of: last.value) {
            base = index
        }
        guard let next = scroll.index(from: base, count: options.count, dx: dx, dy: dy, device: device)
        else { return nil }
        let value = options[next]
        chosen[key] = (value, now)
        var coalescer = writes[key] ?? MonitorWriteCoalescer(interval: interval)
        let action = coalescer.submit(value, at: now)
        writes[key] = coalescer
        switch action {
        case .write: return Turn(key: key, value: value, write: true, due: nil)
        case .wait(let until): return Turn(key: key, value: value, write: false, due: coalescer.pending == nil ? nil : until)
        }
    }

    /// The held writes whose time has come.
    public mutating func due(at now: Double) -> [(key: Key, value: String)] {
        var out: [(key: Key, value: String)] = []
        for key in Array(writes.keys) {
            if let value = writes[key]?.due(at: now) { out.append((key, value)) }
        }
        return out
    }

    /// When the next held write is due, or nil with none held.
    public var nextDue: Double? { writes.values.compactMap(\.dueAt).min() }

    /// Forgets every spin, such as when the camera or its session changes. Held writes are dropped.
    public mutating func reset() {
        scroll.reset()
        lastKey = nil
        chosen = [:]
        writes = [:]
    }
}

extension MonitorWheelDial: Sendable where Key: Sendable {}
extension MonitorWheelDial.Turn: Sendable where Key: Sendable {}
