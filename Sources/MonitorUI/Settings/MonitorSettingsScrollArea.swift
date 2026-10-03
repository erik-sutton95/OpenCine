#if os(iOS)
import SwiftUI
import UIKit

/// Settings content with optional host-owned, per-tab scroll restoration.
/// Native drag-and-drop keeps scrolling enabled so UIKit can deliver drops and edge scrolling.
public struct MonitorSettingsTabScrollArea<Content: View>: View {
    private let tabID: String
    private let savedOffset: Binding<CGFloat>?
    private let content: Content

    public init(
        tabID: String, savedOffset: Binding<CGFloat>? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.tabID = tabID
        self.savedOffset = savedOffset
        self.content = content()
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 22)
                .background {
                    if let savedOffset {
                        MonitorSettingsScrollObserver(savedOffset: savedOffset)
                    }
                }
        }
        .scrollDismissesKeyboard(.interactively)
        .monitorScrollFade()
        .id(tabID)
    }
}

private struct MonitorSettingsScrollObserver: UIViewRepresentable {
    let savedOffset: Binding<CGFloat>

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let coordinator = context.coordinator
        let binding = savedOffset
        Task { @MainActor [weak uiView] in
            guard let uiView else { return }
            var ancestor: UIView? = uiView
            while let current = ancestor {
                if let scrollView = current as? UIScrollView {
                    coordinator.attach(scrollView, savedOffset: binding)
                    return
                }
                ancestor = current.superview
            }
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var savedOffset: Binding<CGFloat>?
        private var active = true
        private var lastReported: CGFloat = -1
        private var lastCommit: CFAbsoluteTime = 0

        func attach(_ view: UIScrollView, savedOffset: Binding<CGFloat>) {
            guard active else { return }
            self.savedOffset = savedOffset
            guard scrollView !== view else { return }
            observation?.invalidate()
            scrollView = view
            view.layoutIfNeeded()
            let maxOffset = max(0, view.contentSize.height - view.bounds.height)
            let restored = min(max(0, savedOffset.wrappedValue), maxOffset)
            if abs(view.contentOffset.y - restored) > 0.5 {
                view.setContentOffset(CGPoint(x: 0, y: restored), animated: false)
            }
            lastReported = restored
            observation = view.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.reportOffset() }
            }
        }

        func detach() {
            active = false
            observation?.invalidate()
            observation = nil
            scrollView = nil
            savedOffset = nil
        }

        private func reportOffset() {
            guard active, let view = scrollView, let savedOffset else { return }
            let offset = view.contentOffset.y
            let maxOffset = max(0, view.contentSize.height - view.bounds.height)
            // Rubber-band positions must not become the next restored position.
            guard offset >= 0, offset <= maxOffset else { return }
            let now = CFAbsoluteTimeGetCurrent()
            guard abs(offset - lastReported) > 10, now - lastCommit >= 1.0 / 15.0 else { return }
            lastReported = offset
            lastCommit = now
            savedOffset.wrappedValue = offset
        }
    }
}
#endif
