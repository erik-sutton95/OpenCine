#if os(iOS)
import SwiftUI

/// A new notice replaces the visible interval. Cancelling an outgoing interval cannot hide
/// its successor; no notice task owns a camera, source or command.
public struct MonitorTransientNotice: View {
    private let text: String
    private let revision: Int
    @State private var visible = false
    public init(text: String, revision: Int) { self.text = text; self.revision = revision }
    public var body: some View {
        Text(text).font(MonitorTheme.font(13, weight: .medium))
            .foregroundStyle(MonitorTheme.text)
            .padding(.horizontal, 14).padding(.vertical, 8).glassCapsule()
            .opacity(visible ? 1 : 0).animation(.easeInOut(duration: 0.2), value: visible)
            .allowsHitTesting(false)
            .task(id: revision) {
                guard revision > 0 else { return }
                visible = true
                do { try await Task.sleep(for: .seconds(2.5)) } catch { return }
                guard !Task.isCancelled else { return }
                visible = false
            }
    }
}
#endif
