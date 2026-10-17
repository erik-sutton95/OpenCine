#if DEBUG
    /// SIMULATED, for the apps' Debug review harnesses only: a camera card holding the staged clips,
    /// which removes what a delete names, as the camera does. Each app's review camera answers its
    /// own camera protocol over it. Compiled out of Release builds.
    @MainActor public final class ReviewCard<Clip> {
        /// The clips on the card, in card order. A harness may stage them after the camera connects.
        public var clips: [Clip]

        public init(clips: [Clip]) { self.clips = clips }

        /// Removes the first clip `names` admits; false (the camera refuses) when the card holds none.
        public func delete(where names: (Clip) -> Bool) -> Bool {
            guard let index = clips.firstIndex(where: names) else { return false }
            clips.remove(at: index)
            return true
        }
    }
#endif
