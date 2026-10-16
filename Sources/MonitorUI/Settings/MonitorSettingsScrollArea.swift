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

    func makeCoordinator() -> MonitorSettingsScrollMemory { MonitorSettingsScrollMemory() }

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

    static func dismantleUIView(_ uiView: UIView, coordinator: MonitorSettingsScrollMemory) {
        coordinator.detach()
    }
}

/// Keeps one settings tab's scroll offset in its host binding and restores it on attach.
///
/// While the page moves, offsets are committed at most 15 times a second and only after a move
/// of more than 10 points, so a drag does not invalidate the host's observers on every frame.
/// The position the page comes to rest at is always committed exactly: once the offset has been
/// still for `settleDelay`, and again when the page goes away, so a reopened tab lands on the
/// same point rather than on the last throttled sample (A2-84).
@MainActor
final class MonitorSettingsScrollMemory {
    private weak var scrollView: UIScrollView?
    private var observation: NSKeyValueObservation?
    private var savedOffset: Binding<CGFloat>?
    private var active = true
    private var lastReported: CGFloat = -1
    private var lastCommit: CFAbsoluteTime = 0
    private let settleDelay: Duration
    private var settling: Task<Void, Never>?

    init(settleDelay: Duration = .milliseconds(120)) {
        self.settleDelay = settleDelay
    }

    func attach(_ view: UIScrollView, savedOffset: Binding<CGFloat>) {
        guard active else { return }
        self.savedOffset = savedOffset
        guard scrollView !== view else { return }
        observation?.invalidate()
        scrollView = view
        view.layoutIfNeeded()
        let restored = min(max(0, savedOffset.wrappedValue), Self.maxOffset(view))
        if abs(view.contentOffset.y - restored) > 0.5 {
            view.setContentOffset(CGPoint(x: 0, y: restored), animated: false)
        }
        lastReported = restored
        observation = view.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.reportOffset() }
        }
    }

    /// Stops observing and commits where the page was left, after the current view update.
    func detach() {
        let final = scrollView.flatMap { restingOffset($0) }
        let binding = savedOffset
        active = false
        settling?.cancel()
        settling = nil
        observation?.invalidate()
        observation = nil
        scrollView = nil
        savedOffset = nil
        if let final, let binding, final != lastReported {
            Task { @MainActor in binding.wrappedValue = final }
        }
    }

    /// Commits the exact offset the page rests at (the trailing edge of the throttle).
    func settle() {
        guard active, let view = scrollView, let savedOffset, let offset = restingOffset(view),
            offset != lastReported
        else { return }
        commit(offset, to: savedOffset)
    }

    private func reportOffset() {
        guard active, let view = scrollView, let savedOffset, let offset = restingOffset(view)
        else { return }
        if abs(offset - lastReported) > 10, CFAbsoluteTimeGetCurrent() - lastCommit >= 1.0 / 15.0 {
            commit(offset, to: savedOffset)
        }
        settling?.cancel()
        let delay = settleDelay
        settling = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.settle()
        }
    }

    private func commit(_ offset: CGFloat, to savedOffset: Binding<CGFloat>) {
        lastReported = offset
        lastCommit = CFAbsoluteTimeGetCurrent()
        savedOffset.wrappedValue = offset
    }

    /// The page's offset, or nil while it rubber-bands past an edge: such a position must not
    /// become the next restored one.
    private func restingOffset(_ view: UIScrollView) -> CGFloat? {
        let offset = view.contentOffset.y
        return offset >= 0 && offset <= Self.maxOffset(view) ? offset : nil
    }

    private static func maxOffset(_ view: UIScrollView) -> CGFloat {
        max(0, view.contentSize.height - view.bounds.height)
    }
}
#endif
