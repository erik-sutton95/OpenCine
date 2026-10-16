import SwiftUI

/// A typed chooser followed, if needed, by integration-owned network or credential steps.
@MainActor
public struct AddSetupFlow: Sendable {
    public var chooser: AddSetupChooser
    public var onSelect: (AddSetupOption) -> Void
    public var destination: ((AddSetupOption) -> AnyView)?
    public nonisolated let initialSelection: String?
    public var onDismiss: () -> Void
    public var onNoticeAction: (String) -> Void
    public var onCancel: () -> Void
    public var cancelTitle: String?

    public init(
        chooser: AddSetupChooser, onSelect: @escaping (AddSetupOption) -> Void,
        destination: ((AddSetupOption) -> AnyView)? = nil, initialSelection: String? = nil,
        onDismiss: @escaping () -> Void = {}, onNoticeAction: @escaping (String) -> Void = { _ in },
        onCancel: @escaping () -> Void = {}, cancelTitle: String? = "Cancel"
    ) {
        self.chooser = chooser
        self.onSelect = onSelect
        self.destination = destination
        self.initialSelection = initialSelection
        self.onDismiss = onDismiss
        self.onNoticeAction = onNoticeAction
        self.onCancel = onCancel
        self.cancelTitle = cancelTitle
    }
    func selecting(_ initialSelection: String?) -> Self {
        Self(
            chooser: chooser, onSelect: onSelect, destination: destination,
            initialSelection: initialSelection,
            onDismiss: onDismiss, onNoticeAction: onNoticeAction, onCancel: onCancel,
            cancelTitle: cancelTitle)
    }

}
