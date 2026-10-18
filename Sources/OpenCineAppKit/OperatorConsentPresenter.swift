#if os(iOS)
    import SwiftUI

    private struct OperatorConsentPresentersKey: EnvironmentKey {
        static let defaultValue: Set<ObjectIdentifier> = []
    }

    extension EnvironmentValues {
        fileprivate var operatorConsentPresenters: Set<ObjectIdentifier> {
            get { self[OperatorConsentPresentersKey.self] }
            set { self[OperatorConsentPresentersKey.self] = newValue }
        }
    }

    private struct OperatorConsentPresenter: ViewModifier {
        let owner: OperatorConsent
        @Environment(\.operatorConsentPresenters) private var ancestors

        func body(content: Content) -> some View {
            if ancestors.contains(ObjectIdentifier(owner)) {
                content
            } else {
                let request = owner.pending
                content
                    .environment(\.operatorConsentPresenters, ancestors.union([ObjectIdentifier(owner)]))
                    .alert(
                        request?.title ?? "",
                        isPresented: Binding(
                            get: { request != nil },
                            set: { if !$0, let request { owner.cancel(request.id) } })
                    ) {
                        if let request {
                            Button(request.confirmTitle, role: .destructive) { owner.confirm(request.id) }
                            Button(request.cancelTitle, role: .cancel) { owner.cancel(request.id) }
                        }
                    } message: {
                        Text(request?.message ?? "")
                    }
            }
        }
    }

    extension View {
        /// Presents this owner's decisions once in a view ancestry. A matching ancestor owns
        /// the reply; an unrelated owner's presenter never suppresses this one.
        public func operatorConsentPresenter(_ owner: OperatorConsent) -> some View {
            modifier(OperatorConsentPresenter(owner: owner))
        }
    }
#endif
