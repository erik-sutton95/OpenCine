import Foundation
import Observation
import OpenCineCore

/// Values and explicit host actions for one operator decision.
@MainActor
public struct OperatorConsentRequest: Identifiable {
    public nonisolated let id: String
    public var title: String
    public var message: String
    public var confirmTitle: String
    public var cancelTitle: String
    var onConfirm: () -> Void
    var onCancel: () -> Void

    public init(
        title: String, message: String, confirmTitle: String, cancelTitle: String = "Cancel",
        id: String = UUID().uuidString, onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }
}

/// One pending decision. Replies consume their ID before invoking the current host;
/// replacement and retirement invalidate replies without sending any command.
@available(macOS 14, *)
@MainActor
@Observable
public final class OperatorConsent {
    /// The current decision for the shell's shared presenter.
    public private(set) var pending: OperatorConsentRequest?
    @ObservationIgnored private var source: AnyHashable?
    @ObservationIgnored private var isCurrent: () -> Bool = { false }
    @ObservationIgnored private var settledIDs: Set<String> = []

    public init() {}

    /// Presents a current host decision; repeated publication keeps the same pending reply.
    public func present(
        _ request: OperatorConsentRequest, source: AnyHashable,
        isCurrent: @escaping () -> Bool = { true }
    ) {
        guard !settledIDs.contains(request.id), pending?.id != request.id || self.source != source
        else { return }
        retire()
        self.source = source
        self.isCurrent = isCurrent
        pending = request
    }

    /// Adapts an integration's neutral confirmation without depending on that integration.
    public func present(
        _ prompt: any ConfirmationPrompt, source: AnyHashable,
        isCurrent: @escaping () -> Bool = { true }
    ) {
        present(
            OperatorConsentRequest(
                title: prompt.confirmationTitle, message: prompt.fallbackText,
                confirmTitle: prompt.confirmTitle, cancelTitle: prompt.cancelTitle,
                id: prompt.confirmationID,
                onConfirm: prompt.confirm, onCancel: prompt.cancel),
            source: source, isCurrent: isCurrent)
    }

    /// Admits only a current, unanswered confirmation.
    public func confirm(_ id: String) { consume(id, confirmed: true) }

    /// Declines only a current, unanswered decision.
    public func cancel(_ id: String) { consume(id, confirmed: false) }

    /// Invalidates a retired source without invoking either host action; nil retires all.
    public func retire(source: AnyHashable? = nil) {
        guard source == nil || self.source == source else { return }
        if let pending { settledIDs.insert(pending.id) }
        self.source = nil
        isCurrent = { false }
        pending = nil
    }

    private func consume(_ id: String, confirmed: Bool) {
        guard let request = pending, request.id == id else { return }
        let admits = isCurrent
        retire()
        guard admits() else { return }
        if confirmed { request.onConfirm() } else { request.onCancel() }
    }
}
