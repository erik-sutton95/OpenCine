#if os(iOS)
    import MonitorPresentation
    import SwiftUI

    /// Shared launch geometry over the host's brand content. Fonts, colors, images, fallback marks
    /// and accessibility labels remain host values and views.
    @MainActor
    public struct MonitorLaunchSplashContent<Backdrop: View, Mark: View, Wordmark: View>: View {
        private let compact: Bool
        private let backdrop: () -> Backdrop
        private let mark: (CGFloat) -> Mark
        private let wordmark: (CGFloat) -> Wordmark

        public init(
            compact: Bool = false, @ViewBuilder backdrop: @escaping () -> Backdrop,
            @ViewBuilder mark: @escaping (CGFloat) -> Mark,
            @ViewBuilder wordmark: @escaping (CGFloat) -> Wordmark
        ) {
            self.compact = compact
            self.backdrop = backdrop
            self.mark = mark
            self.wordmark = wordmark
        }

        public var body: some View {
            GeometryReader { proxy in
                let layout = MonitorLaunchLayout(
                    width: proxy.size.width, height: proxy.size.height, compact: compact)
                ZStack {
                    backdrop()
                    if layout.landscape {
                        HStack(spacing: layout.spacing) {
                            mark(layout.logoSize)
                            wordmark(layout.wordmarkSize)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, layout.horizontalInset)
                    } else {
                        VStack(spacing: layout.spacing) {
                            mark(layout.logoSize)
                            wordmark(layout.wordmarkSize)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }

    /// The host retains overlay placement and z-order. Only visibility, fade and touch admission
    /// are shared, with the same launch timing the startup lifetime consumes.
    @MainActor public struct MonitorLaunchSplashOverlay<Content: View>: View {
        @Binding private var isVisible: Bool
        private let content: Content

        public init(isVisible: Binding<Bool>, @ViewBuilder content: () -> Content) {
            _isVisible = isVisible
            self.content = content()
        }

        public var body: some View {
            content
                .opacity(isVisible ? 1 : 0)
                .animation(
                    .easeOut(duration: MonitorLaunchTiming.fadeOutDuration), value: isVisible
                )
                .allowsHitTesting(isVisible)
                // While it shows, one element over its whole frame: an accessibility hit test
                // (VoiceOver, a UI test's hittability) meets the splash as a touch does, not the
                // controls already laid out beneath it.
                .accessibilityElement(children: .combine)
                .accessibilityHidden(!isVisible)
                .accessibilityIdentifier("monitor-launch-splash")
        }
    }
#endif
