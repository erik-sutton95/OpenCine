import Foundation

/// A producer revision changes whenever the source or control lease changes, including ABA changes.
public struct MonitorWatcherContext: Equatable, Sendable {
    public let source: String
    public let revision: UInt64
    public let canControl: Bool
    public let recording: Bool
    public init(source: String, revision: UInt64, canControl: Bool, recording: Bool) {
        self.source = source; self.revision = revision; self.canControl = canControl; self.recording = recording
    }
    public var tapSource: MonitorWatcherTapSource {
        .init(source: source, revision: revision, canControl: canControl)
    }
}

/// A picture gesture belongs to one source and lease; recording reports do not change it.
public struct MonitorWatcherTapSource: Hashable, Sendable {
    public let source: String
    public let revision: UInt64
    public let canControl: Bool
    public init(source: String, revision: UInt64, canControl: Bool) {
        self.source = source; self.revision = revision; self.canControl = canControl
    }
    public func admits(_ current: MonitorWatcherTapSource) -> Bool {
        canControl && current.canControl && source == current.source && revision == current.revision
    }
}

public struct MonitorWatcherFocus: Equatable, Sendable {
    public let source: MonitorWatcherTapSource
    public let x: Double
    public let y: Double
    public init(source: MonitorWatcherTapSource, x: Double, y: Double) {
        self.source = source; self.x = x; self.y = y
    }
}

public enum MonitorWatcherSetting: String, Equatable, Sendable { case iso, shutter, zoom }
public struct MonitorWatcherChoice: Equatable, Sendable, Identifiable {
    public let id: Int
    public let title: String
    public init(id: Int, title: String) { self.id = id; self.title = title }
}
public struct MonitorWatcherSettingValue: Equatable, Sendable, Identifiable {
    public let id: MonitorWatcherSetting
    public let title: String
    public let choices: [MonitorWatcherChoice]
    public init(id: MonitorWatcherSetting, title: String, choices: [MonitorWatcherChoice]) {
        self.id = id; self.title = title; self.choices = choices
    }
}
public struct MonitorWatcherReading: Equatable, Sendable, Identifiable {
    public let id: String
    public let value: String?
    public init(_ title: String, value: String?) { self.id = title; self.value = value?.isEmpty == false ? value : nil }
}
public struct MonitorWatcherNotice: Equatable, Sendable {
    public let message: String
    public let canChooseFeed: Bool
    public init(_ message: String, canChooseFeed: Bool = false) { self.message = message; self.canChooseFeed = canChooseFeed }
}
public struct MonitorWatcherPresentation: Equatable, Sendable {
    public let context: MonitorWatcherContext
    public let hostTitle: String
    public let receivedFPS: Int?
    public let readings: [MonitorWatcherReading]
    public let settings: [MonitorWatcherSettingValue]
    public let holderName: String
    public let canRequestControl: Bool
    public let controlRequested: Bool
    public let notice: MonitorWatcherNotice?
    public init(context: MonitorWatcherContext, hostTitle: String, receivedFPS: Int?,
        readings: [MonitorWatcherReading], settings: [MonitorWatcherSettingValue], holderName: String,
        canRequestControl: Bool, controlRequested: Bool, notice: MonitorWatcherNotice?) {
        self.context = context; self.hostTitle = hostTitle; self.receivedFPS = receivedFPS
        self.readings = readings; self.settings = settings; self.holderName = holderName
        self.canRequestControl = canRequestControl; self.controlRequested = controlRequested; self.notice = notice
    }
    public func admits(_ action: MonitorWatcherAction) -> Bool {
        switch action {
        case .set(let captured, let setting, let choice):
            return captured == context && context.canControl && settings.contains { $0.id == setting && $0.choices.contains { $0.id == choice } }
        case .record(let captured, let desired):
            return captured == context && context.canControl && desired != context.recording
        case .requestControl: return canRequestControl && !controlRequested
        case .releaseControl: return context.canControl
        case .chooseFeed: return notice?.canChooseFeed == true
        case .leave: return true
        }
    }
}
public enum MonitorWatcherAction: Equatable, Sendable {
    case leave, chooseFeed, requestControl, releaseControl
    case set(MonitorWatcherContext, MonitorWatcherSetting, Int)
    case record(MonitorWatcherContext, Bool)
}

/// The dialog captures an explicit target under one source/lease/report. Closing sends nothing.
public struct MonitorWatcherInteraction: Equatable, Sendable {
    public private(set) var pendingRecording: MonitorWatcherContext?
    public private(set) var focus: MonitorWatcherFocus?
    public init() {}
    @discardableResult public mutating func applyFocus(_ value: MonitorWatcherFocus, current: MonitorWatcherTapSource) -> Bool {
        guard value.source.admits(current) else { return false }
        focus = value
        return true
    }
    public mutating func retireFocus(current: MonitorWatcherTapSource) {
        if let focus, !focus.source.admits(current) { self.focus = nil }
    }
    public mutating func update(context: MonitorWatcherContext, clean: Bool) {
        if clean || pendingRecording != context { cancel() }
    }
    public mutating func requestRecording(context: MonitorWatcherContext, confirm: Bool) -> MonitorWatcherAction? {
        cancel()
        guard context.canControl else { return nil }
        if confirm { pendingRecording = context; return nil }
        return .record(context, !context.recording)
    }
    public mutating func confirmRecording(context: MonitorWatcherContext) -> MonitorWatcherAction? {
        let captured = pendingRecording
        cancel()
        guard let captured, captured == context, context.canControl else { return nil }
        return .record(context, !captured.recording)
    }
    public mutating func cancel() { pendingRecording = nil }
}
