#if os(iOS)
    import SwiftUI

    /// Legal destinations stay with the app, including in-app documents and external URLs.
    struct CameraLegalLinks: View {
        var onPrivacy: (() -> Void)?
        var onTerms: (() -> Void)?

        var body: some View {
            if onPrivacy != nil || onTerms != nil {
                HStack(spacing: 20) {
                    if let onPrivacy { link("Privacy", id: "legal.privacy", action: onPrivacy) }
                    if let onTerms { link("Terms", id: "legal.terms", action: onTerms) }
                }
                .frame(maxWidth: .infinity)
            }
        }

        private func link(_ title: String, id: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Text(title)
                    .font(MonitorTheme.font(11)).foregroundStyle(MonitorTheme.secondary)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier(id)
        }
    }
#endif
