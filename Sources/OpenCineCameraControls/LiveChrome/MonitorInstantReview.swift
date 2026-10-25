#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import SwiftUI
    import UIKit

    private typealias Layout = MonitorInstantReviewLayout

    /// Test and automation identifiers of the instant review (Kotlin `MonitorInstantReviewIds`).
    public enum MonitorInstantReviewIDs {
        public static let review = "monitor.instantReview"
        public static let close = "monitor.instantReview.close"
        public static let favorite = "monitor.instantReview.favorite"
        public static let info = "monitor.instantReview.info"
    }

    /// The post-capture instant review, the one component every app shows after a still capture.
    /// The captured still fills the whole monitor over black, above every piece of chrome; a tap
    /// anywhere or the close button dismisses it (the host owns the timed dismissal). While the
    /// embedded stand-in thumb shows, it is blurred behind a spinner and the blur clears as the
    /// sharp still swaps in. The favorite star (absent when `favorited` is nil: nothing on the card
    /// to rate) stacks over the capture settings line at the bottom. `marks` draws over the fitted
    /// still (AF boxes), given its frame in this view's points. Geometry:
    /// `MonitorInstantReviewLayout`. Kotlin twin: `MonitorInstantReview` in camera-controls.
    public struct MonitorInstantReview<Palette: LiveChromePalette, Marks: View>: View {
        private let image: UIImage
        private let displaySize: CGSize?
        private let isFullResolution: Bool
        private let favorited: Bool?
        private let onToggleFavorite: (Bool) -> Void
        private let infoLine: String?
        private let onDismiss: () -> Void
        private let marks: (CGRect) -> Marks

        /// - Parameter displaySize: the still's displayed size (de-squeezed); nil uses the image's.
        public init(
            image: UIImage, displaySize: CGSize? = nil, isFullResolution: Bool,
            favorited: Bool? = nil, onToggleFavorite: @escaping (Bool) -> Void = { _ in },
            infoLine: String? = nil, onDismiss: @escaping () -> Void,
            @ViewBuilder marks: @escaping (CGRect) -> Marks
        ) {
            self.image = image
            self.displaySize = displaySize
            self.isFullResolution = isFullResolution
            self.favorited = favorited
            self.onToggleFavorite = onToggleFavorite
            self.infoLine = infoLine
            self.onDismiss = onDismiss
            self.marks = marks
        }

        public var body: some View {
            ZStack(alignment: .topTrailing) {
                Color.black
                GeometryReader { proxy in
                    let size = displaySize ?? image.size
                    let frame = Layout.imageFrame(
                        imageWidth: size.width, imageHeight: size.height,
                        containerWidth: proxy.size.width, containerHeight: proxy.size.height)
                    let fitted = CGRect(
                        x: frame.x, y: frame.y, width: frame.width, height: frame.height)
                    // The stand-in thumb shows blurred; the upgrade animates the blur away as the
                    // full image swaps underneath, reading as one continuous sharpen.
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                        .blur(radius: isFullResolution ? 0 : Layout.standInBlur, opaque: true)
                        .clipped()
                    marks(fitted)
                }
                if !isFullResolution {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Palette.text.opacity(0.9))
                        .frame(width: Layout.spinnerSize, height: Layout.spinnerSize)
                        .scaleEffect(1.4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                }
                VStack(spacing: Layout.stackSpacing) {
                    Spacer()
                    if let favorited {
                        Button {
                            onToggleFavorite(!favorited)
                        } label: {
                            MonitorIcon.star.view(filled: favorited)
                                .frame(
                                    width: Layout.favoriteGlyphSize,
                                    height: Layout.favoriteGlyphSize
                                )
                                .foregroundStyle(
                                    favorited ? Palette.accent : Palette.text.opacity(0.85)
                                )
                                .frame(width: Layout.favoriteSize, height: Layout.favoriteSize)
                                .liquidGlass(in: Circle(), interactive: true)
                        }
                        .buttonStyle(.monitorTapTarget)
                        .accessibilityLabel(
                            favorited ? "Remove favorite star" : "Favorite this shot"
                        )
                        .accessibilityIdentifier(MonitorInstantReviewIDs.favorite)
                    }
                    if let infoLine {
                        Text(infoLine)
                            .font(
                                .system(
                                    size: Layout.infoFontSize, weight: .semibold,
                                    design: .monospaced)
                            )
                            .foregroundStyle(Palette.text.opacity(0.85))
                            .lineLimit(1)
                            .padding(.horizontal, Layout.infoHorizontalPadding)
                            .padding(.vertical, Layout.infoVerticalPadding)
                            .liquidGlass(in: Capsule())
                            .accessibilityIdentifier(MonitorInstantReviewIDs.info)
                    }
                }
                .padding(.bottom, Layout.bottomInset)
                .frame(maxWidth: .infinity)
                LiveCloseButton<Palette>(action: onDismiss, size: Layout.closeSize)
                    .accessibilityIdentifier(MonitorInstantReviewIDs.close)
                    .padding(Layout.closeInset)
            }
            .animation(.easeInOut(duration: Layout.sharpenSeconds), value: isFullResolution)
            .contentShape(Rectangle())
            .onTapGesture(perform: onDismiss)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Instant playback")
            .accessibilityIdentifier(MonitorInstantReviewIDs.review)
            .ignoresSafeArea()
        }
    }

    extension MonitorInstantReview where Marks == EmptyView {
        public init(
            image: UIImage, displaySize: CGSize? = nil, isFullResolution: Bool,
            favorited: Bool? = nil, onToggleFavorite: @escaping (Bool) -> Void = { _ in },
            infoLine: String? = nil, onDismiss: @escaping () -> Void
        ) {
            self.init(
                image: image, displaySize: displaySize, isFullResolution: isFullResolution,
                favorited: favorited, onToggleFavorite: onToggleFavorite, infoLine: infoLine,
                onDismiss: onDismiss, marks: { _ in EmptyView() })
        }
    }
#endif
