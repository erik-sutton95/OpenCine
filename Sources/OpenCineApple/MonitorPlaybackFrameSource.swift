#if canImport(UIKit) && canImport(AVFoundation)
    import AVFoundation
    import OpenCineMedia

    /// The native picture source behind one playback item: the player its item plays in, the
    /// shared feed that the picture, scopes and backdrop read, and the item callback the assists
    /// attach to. `MonitorApplePlaybackOwner` is the plain file source; an integration with its
    /// own file lifetime (for example a camera cache that is still growing) conforms as another
    /// source over the same feed, so every app keeps one playback engine.
    ///
    /// A conforming source prepares the feed for each item before it becomes the player's
    /// current item (`feed.prepare`), retires it when the item goes (`feed.beginSourceChange`),
    /// notes readiness (`feed.noteItemReady`) and shuts the feed down when it closes.
    @MainActor public protocol MonitorPlaybackFrameSource: MonitorPlaybackPort {
        var player: AVPlayer { get }
        var feed: MonitorPlaybackFeedSession { get }
        /// Called with each installed item, and with `nil` when the current item retires.
        var onItemChanged: (@MainActor (AVPlayerItem?) -> Void)? { get set }
        /// How far the native item has buffered while `token` is its current item.
        func bufferedThroughSeconds(token: MonitorPlaybackItemToken) -> Double?
    }

    extension MonitorApplePlaybackOwner: MonitorPlaybackFrameSource {}
#endif
