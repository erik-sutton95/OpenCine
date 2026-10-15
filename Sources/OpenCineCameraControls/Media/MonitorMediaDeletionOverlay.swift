#if os(iOS)
import MonitorUI
import OpenCineAppKit
import SwiftUI

/// Shared progress card for an admitted deletion; the source supplies companion-file detail.
public struct MonitorMediaDeletionOverlay: View {
    private let progress: MonitorMediaDeletionProgress
    private let detail: String?

    public init(progress: MonitorMediaDeletionProgress, detail: String? = nil) {
        self.progress = progress
        self.detail = detail
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 6) {
                Text("Deleting \(progress.selectedCount) \(progress.selectedCount == 1 ? "item" : "items")…")
                    .font(MonitorTheme.font(14, weight: .semibold)).foregroundStyle(MonitorTheme.text)
                Text(detail ?? "\(progress.completed) of \(progress.total)")
                    .font(MonitorTheme.font(11)).foregroundStyle(MonitorTheme.muted)
                ProgressView(value: progress.total == 0 ? 0 : Double(progress.completed) / Double(progress.total))
                    .tint(MonitorTheme.accent).frame(width: 220).padding(.top, 6)
            }.padding(.horizontal, 24).padding(.vertical, 20)
                .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }.allowsHitTesting(true)
    }
}
#endif
