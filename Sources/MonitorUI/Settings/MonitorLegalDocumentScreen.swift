#if os(iOS)
import MonitorPresentation
import SwiftUI

/// One legal page over the whole window, from values only. Bundled text scrolls; a page this build
/// does not carry says so instead of showing an empty page. Web pages never render here: the
/// host opens them through its browser route.
public struct MonitorLegalDocumentScreen: View {
    private let wordmark: String
    private let page: MonitorLegalPage
    private let document: MonitorLegalDocument
    private let onClose: () -> Void

    public init(documents: MonitorLegalDocuments, page: MonitorLegalPage, onClose: @escaping () -> Void) {
        wordmark = documents.wordmark; self.page = page; document = documents[page]; self.onClose = onClose
    }

    /// What a page this build does not carry says.
    public static let unavailableText = MonitorLegalDocuments.unavailableText

    var bodyText: String {
        switch document {
        case .text(let text): text
        case .link(let url): url.absoluteString
        case .unavailable: Self.unavailableText
        }
    }

    public var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            ZStack(alignment: .topLeading) {
                MonitorTheme.background
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(wordmark)
                            .font(MonitorTheme.font(9.5, weight: .bold)).kerning(0.8)
                            .foregroundStyle(MonitorTheme.accent).textCase(.uppercase)
                        Text(page.title)
                            .font(MonitorTheme.font(24, weight: .semibold)).foregroundStyle(MonitorTheme.text)
                            .accessibilityAddTraits(.isHeader)
                    }
                    .padding(.leading, OperatorPanelMetrics.closeButtonClearance(safeArea: insets))
                    ScrollView {
                        Text(bodyText)
                            .font(MonitorTheme.font(14, weight: .regular)).foregroundStyle(MonitorTheme.text)
                            .lineSpacing(5).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            .background(MonitorTheme.surface, in: RoundedRectangle(cornerRadius: MonitorTheme.radius))
                            .overlay(RoundedRectangle(cornerRadius: MonitorTheme.radius)
                                .stroke(MonitorTheme.border, lineWidth: 1))
                            .accessibilityIdentifier("legal.document.\(page.rawValue)")
                    }
                    .monitorScrollFade()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, OperatorPanelMetrics.topPadding(safeArea: insets))
                .padding(.leading, OperatorPanelMetrics.leadingPadding(safeArea: insets))
                .padding(.trailing, OperatorPanelMetrics.trailingPadding(safeArea: insets))
                .padding(.bottom, OperatorPanelMetrics.bottomPadding(safeArea: insets))
                Button(action: onClose) {
                    MonitorIcon.x
                        .frame(width: OperatorPanelMetrics.closeSize * 0.38, height: OperatorPanelMetrics.closeSize * 0.38)
                        .foregroundStyle(MonitorTheme.text)
                        .frame(width: OperatorPanelMetrics.closeSize, height: OperatorPanelMetrics.closeSize)
                        .glassCircle(interactive: true)
                }
                .buttonStyle(.monitorTapTarget)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("legal.document.close")
                .padding(.leading, OperatorPanelMetrics.closeLeading)
                .padding(.top, OperatorPanelMetrics.closeTopPadding(safeArea: insets))
            }
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
    }
}
#endif
