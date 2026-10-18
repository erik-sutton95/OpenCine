#if os(iOS)
    import SwiftUI
    import UIKit

    /// One shared diagnostics bundle, identified by its written report's URL.
    public struct MonitorDiagnosticsShareItem: Identifiable, Equatable {
        public let id = UUID()
        public let url: URL

        public init(url: URL) { self.url = url }
    }

    /// The plain share sheet every app showed through its own `UIActivityViewController`
    /// wrapper (A2-64). Presented as a sheet over any host; the host dismisses it.
    public struct MonitorActivityShareSheet: UIViewControllerRepresentable {
        public let items: [Any]

        public init(items: [Any]) { self.items = items }

        public func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: items, applicationActivities: nil)
        }

        public func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
    }
#endif
