import Foundation

/// Which aspect the portrait feed renders at (operator pinch, persisted). Raw values are
/// stored in user settings: never rename them.
public enum PortraitFeedAspect: String, Codable, Equatable, Sendable {
    /// Full-width strip; whole image visible (16:9 letterboxed within the portrait width).
    case fit16x9
    /// Fills topBar→systemBar; center-crop zoom.
    case fill
}

/// Decoded raster geometry for the feed well.
public enum FeedRaster {
    /// Aspect for the feed well. Unknown / degenerate rasters keep the fallback (landscape 16:9).
    public static func aspect(width: Int, height: Int, fallback: Double = 16.0 / 9.0) -> Double {
        guard width > 1, height > 1 else { return fallback }
        return Double(width) / Double(height)
    }

    /// The raster is taller than it is wide (for example a camera screen flip).
    public static func isVertical(width: Int, height: Int) -> Bool {
        width > 1 && height > 1 && height > width
    }
}
