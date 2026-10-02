import MonitorPresentation
import SwiftUI

/// An integration's preparation steps inside the shared pair page's rail and pane.
/// Pass `nil` to `PairScreen.pairingFlow` when the connection model takes over progress.
public struct IntegrationPairingFlow {
    public var presentation: CameraPairingPresentation
    public var onSelect: (String) -> Void
    public var onPrimary: () -> Void
    public var onBack: () -> Void
    public var content: AnyView

    public init(
        presentation: CameraPairingPresentation,
        onSelect: @escaping (String) -> Void = { _ in },
        onPrimary: @escaping () -> Void,
        onBack: @escaping () -> Void,
        content: AnyView
    ) {
        self.presentation = presentation
        self.onSelect = onSelect
        self.onPrimary = onPrimary
        self.onBack = onBack
        self.content = content
    }
}
