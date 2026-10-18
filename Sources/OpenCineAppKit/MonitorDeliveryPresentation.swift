import Foundation
import Observation
import OpenCineCore

/// Captured native task facts; this value never schedules or chooses an operation.
@MainActor public struct MonitorDeliveryExternalOperation: Sendable {
    public let active: @MainActor () -> Bool
    public let cancel: @MainActor () -> Void
    public init(active: @escaping @MainActor () -> Bool, cancel: @escaping @MainActor () -> Void) {
        self.active = active
        self.cancel = cancel
    }
}
@MainActor public final class MonitorDeliveryExternalTicket<Progress: Sendable> {
    fileprivate let operation: MonitorDeliveryExternalOperation?
    fileprivate let terminal: AsyncStream<String?>
    fileprivate let continuation: AsyncStream<String?>.Continuation
    fileprivate var completed = false
    fileprivate var report: ((Progress) -> Void)?
    fileprivate var pendingProgress: Progress?
    fileprivate var callerFinished = false
    fileprivate init(_ operation: MonitorDeliveryExternalOperation?) {
        self.operation = operation
        let pair = AsyncStream<String?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        terminal = pair.stream
        continuation = pair.continuation
    }
    fileprivate func complete(_ message: String?) {
        guard !completed else { return }
        completed = true
        continuation.yield(message)
        continuation.finish()
    }
}
public struct MonitorDeliveryPresentationDisplay<Progress: Sendable>: Sendable {
    public let overlay: Progress?
    public let toast: String?
    public let expanded: Bool
    public init(overlay: Progress? = nil, toast: String? = nil, expanded: Bool = false) {
        self.overlay = overlay
        self.toast = toast
        self.expanded = expanded
    }
}

/// Existing native/external progress, chrome and toast contexts with captured completion priority.
@available(macOS 14, *) @MainActor @Observable
public final class MonitorDeliveryPresentation<Progress: Sendable> {
    private enum Intent: Equatable { case native, external }
    private final class NativeTicket {}
    @ObservationIgnored private let native: MonitorDeliveryModel<Progress, String?, Bool>
    @ObservationIgnored private let external: MonitorDeliveryModel<Progress, String?, Bool>
    @ObservationIgnored private let chrome: MonitorDeliveryModel<Bool, Bool, Bool>
    @ObservationIgnored private let notifications: MonitorDeliveryModel<Bool, Bool, Bool>
    @ObservationIgnored private let isCaching: (Progress) -> Bool
    @ObservationIgnored private let isExternalDelivery: (Progress) -> Bool
    private var presented: Intent?
    @ObservationIgnored private var nativeTicket: NativeTicket?
    @ObservationIgnored private var ticket: MonitorDeliveryExternalTicket<Progress>?
    @ObservationIgnored private var closed = false
    public init(
        isCaching: @escaping (Progress) -> Bool, isExternalDelivery: @escaping (Progress) -> Bool,
        sleep: @escaping @MainActor (Duration) async throws -> Void = hostSleep(for:)
    ) {
        self.isCaching = isCaching
        self.isExternalDelivery = isExternalDelivery
        native = .init(sleep: sleep)
        external = .init(sleep: sleep)
        chrome = .init(sleep: sleep)
        notifications = .init(sleep: sleep)
    }
    public var display: MonitorDeliveryPresentationDisplay<Progress> {
        .init(overlay: overlayState, toast: completionToast, expanded: isExpanded)
    }
    public var overlayState: Progress? {
        switch presented {
        case .native: native.state.progress
        case .external: external.state.progress
        case nil: nil
        }
    }
    public var completionToast: String? { notifications.state.toast }
    public var isExpanded: Bool {
        get { chrome.state.expanded }
        set { chrome.setExpanded(newValue) }
    }
    public var nativeRunning: Bool { native.state.running }
    public var nativeState: MonitorDeliveryState<Progress, Bool> { native.state }
    public func beginNative(
        operation: @escaping @MainActor (@escaping @MainActor (Progress) -> Void) async -> String?
    ) {
        _ = beginNativeCaptured { report, _ in await operation(report) }
    }
    @discardableResult public func beginNativeCaptured(
        operation:
            @escaping @MainActor (@escaping @MainActor (Progress) -> Void, MonitorDeliveryAdmission)
            async -> String?
    ) -> MonitorDeliveryRunHandle? {
        guard !closed else { return nil }
        let captured = NativeTicket()
        nativeTicket = captured
        presented = .native
        guard nativeTicket === captured, !closed else { return nil }
        chrome.setExpanded(false)
        guard nativeTicket === captured, !closed else { return nil }
        return native.beginCaptured(
            onComplete: { message in
                if self.nativeTicket === captured, !self.closed {
                    self.presented = nil
                    guard self.nativeTicket === captured, !self.closed else { return nil }
                    self.chrome.setExpanded(false)
                    if self.nativeTicket === captured, !self.closed, let message {
                        self.showToast(message: message)
                    }
                }
                return nil
            },
            operation: { report, admission in
                let message = await operation(
                    { progress in
                        guard !self.closed, self.nativeTicket === captured, !Task.isCancelled else {
                            return
                        }
                        self.presented = .native
                        report(progress)
                    }, admission)
                return .init(message)
            })
    }
    public func trackExternalDelivery(
        operation: MonitorDeliveryExternalOperation?
    ) -> MonitorDeliveryExternalTicket<Progress> {
        let captured = MonitorDeliveryExternalTicket<Progress>(operation)
        guard !closed else {
            captured.callerFinished = true
            return captured
        }
        captured.pendingProgress = presented == .external ? overlayState : nil
        ticket = captured
        external.begin(
            onCancel: {
                if !captured.callerFinished { captured.operation?.cancel() }
            },
            onComplete: { message in
                if self.ticket === captured {
                    self.presented = nil
                    guard self.ticket === captured, !self.closed else { return nil }
                    self.chrome.setExpanded(false)
                    if self.ticket === captured, !self.closed, let message {
                        self.showToast(message: message)
                    }
                }
                return nil
            },
            operation: { report in
                captured.report = report
                if let progress = captured.pendingProgress { report(progress) }
                captured.pendingProgress = nil
                for await message in captured.terminal { return .init(message) }
                return .init(nil)
            })
        return captured
    }
    public func finishExternalDelivery(_ captured: MonitorDeliveryExternalTicket<Progress>) {
        guard ticket === captured, !closed else { return }
        captured.callerFinished = true
        if let progress = overlayState, isCaching(progress), !nativeRunning,
            ticket === captured, !closed
        {
            presented = nil
            guard ticket === captured, !closed else { return }
            chrome.setExpanded(false)
            if ticket === captured, !closed { external.cancel() }
        }
    }
    public func publishCache(
        _ captured: MonitorDeliveryExternalTicket<Progress>, progress: Progress
    ) {
        guard !closed, ticket === captured else { return }
        presented = .external
        if let report = captured.report {
            report(progress)
        } else {
            captured.pendingProgress = progress
        }
    }
    public func publishExternalDelivery(
        _ captured: MonitorDeliveryExternalTicket<Progress>, progress: Progress
    ) {
        if !closed, ticket === captured, !nativeRunning {
            publishCache(captured, progress: progress)
        }
    }
    public func completeExternalDelivery(
        _ captured: MonitorDeliveryExternalTicket<Progress>, message: String?
    ) {
        if !closed, ticket === captured, !nativeRunning { captured.complete(message) }
    }
    public func noteExternalIdle(_ captured: MonitorDeliveryExternalTicket<Progress>) {
        guard !closed, ticket === captured, !nativeRunning,
            captured.operation?.active() != true,
            !closed, ticket === captured, !nativeRunning
        else { return }
        if let progress = overlayState, isExternalDelivery(progress),
            !closed, ticket === captured, !nativeRunning
        {
            presented = nil
            guard ticket === captured, !closed else { return }
            chrome.setExpanded(false)
            if ticket === captured, !closed { external.cancel() }
        }
    }
    public func showToast(message: String) {
        guard !closed else { return }
        notifications.begin { _ in .init(false, toast: message) }
    }
    public func dismissToast() { notifications.dismissToast() }
    public func cancel() {
        let retiringExternal = ticket
        nativeTicket = nil
        ticket = nil
        presented = nil
        if nativeTicket == nil, ticket == nil { chrome.setExpanded(false) }
        if nativeTicket == nil { native.cancel() }
        if ticket == nil {
            external.cancel()
        } else if retiringExternal?.callerFinished == false {
            retiringExternal?.operation?.cancel()
        }
    }
    public func close() {
        guard !closed else { return }
        closed = true
        cancel()
        native.close()
        external.close()
        chrome.close()
        notifications.close()
    }
}
