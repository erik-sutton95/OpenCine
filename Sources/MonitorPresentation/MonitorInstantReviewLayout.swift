import Foundation

/// Geometry of the post-capture instant review: the just-captured still over the whole monitor,
/// above every piece of chrome, with a round close button in the top trailing corner and the
/// favorite star stacked over the capture settings line at the bottom centre. Points; the
/// container is the full physical window (the review ignores the safe area). Kotlin twin:
/// `MonitorInstantReviewLayout` in monitor-ui.
public enum MonitorInstantReviewLayout {
    /// Round close button side.
    public static let closeSize: Double = 34
    /// Close button inset from the top and trailing edges.
    public static let closeInset: Double = 14
    /// Round favorite button side.
    public static let favoriteSize: Double = 42
    /// Star glyph side inside the favorite button.
    public static let favoriteGlyphSize: Double = 19
    /// Gap between the favorite button and the capture settings line.
    public static let stackSpacing: Double = 10
    /// The bottom stack's inset from the bottom edge.
    public static let bottomInset: Double = 14
    /// Capture settings line type size (monospaced, semibold).
    public static let infoFontSize: Double = 13
    public static let infoHorizontalPadding: Double = 14
    public static let infoVerticalPadding: Double = 7
    /// Blur over the embedded stand-in thumb until the sharp still lands.
    public static let standInBlur: Double = 14
    /// Spinner side over the stand-in thumb.
    public static let spinnerSize: Double = 28
    /// The blur clearing as the sharp still swaps in reads as one sharpen.
    public static let sharpenSeconds: Double = 0.4

    /// Aspect fit of the (already de-squeezed) still inside the container, centred. Empty when
    /// either size is degenerate, so nothing draws rather than a stretched frame.
    public static func imageFrame(
        imageWidth: Double, imageHeight: Double, containerWidth: Double, containerHeight: Double
    ) -> MonitorRect {
        guard imageWidth > 0, imageHeight > 0, containerWidth > 0, containerHeight > 0 else {
            return MonitorRect()
        }
        let scale = min(containerWidth / imageWidth, containerHeight / imageHeight)
        let width = imageWidth * scale
        let height = imageHeight * scale
        return MonitorRect(
            x: (containerWidth - width) / 2, y: (containerHeight - height) / 2,
            width: width, height: height)
    }

    /// The close button, pinned to the top trailing corner.
    public static func closeFrame(containerWidth: Double) -> MonitorRect {
        MonitorRect(
            x: max(0, containerWidth - closeInset - closeSize), y: closeInset,
            width: closeSize, height: closeSize)
    }

    /// The favorite button, centred above the capture settings line (`infoHeight`, nil when the
    /// line is hidden) at the bottom of the container.
    public static func favoriteFrame(
        containerWidth: Double, containerHeight: Double, infoHeight: Double?
    ) -> MonitorRect {
        let below = infoHeight.map { $0 + stackSpacing } ?? 0
        return MonitorRect(
            x: (containerWidth - favoriteSize) / 2,
            y: max(0, containerHeight - bottomInset - below - favoriteSize),
            width: favoriteSize, height: favoriteSize)
    }
}
