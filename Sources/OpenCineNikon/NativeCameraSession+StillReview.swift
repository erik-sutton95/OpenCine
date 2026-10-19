#if canImport(Darwin) && canImport(os)
    import Foundation

    // Instant review on the iOS session; the Android facade runs the same steps in
    // `OpenCineNikonAndroid/MediaBrowse.swift`. The rules live in `NikonStillReview.swift`.
    extension NativeCameraSession {
        /// Seeds `tracker` with every card's current object handles, so the first
        /// post-capture diff has a baseline. A card whose listing fails is left out.
        public func seedStillReviewBaseline(tracker: NikonStillReviewObjectTracker) async {
            tracker.seed(listing: await stillReviewListing())
        }

        /// One lookup for the review object of the shot just captured: the handles the camera
        /// announced with `ObjectAdded`, else a card diff against the baseline. Nil while the
        /// shot has not reached the card yet; the shell retries within
        /// ``NikonStillReviewPolicy/objectWindowMilliseconds``.
        public func resolveStillReviewObject(
            tracker: NikonStillReviewObjectTracker
        ) async -> NikonStillReviewSelection.Choice? {
            var candidates = tracker.takeAnnounced()
            if candidates.isEmpty {
                candidates = tracker.absorb(listing: await stillReviewListing())
            }
            var selection = NikonStillReviewSelection()
            var offered: [UInt32] = []
            for handle in candidates {
                guard let info = try? await getObjectInfo(handle: handle) else { continue }
                offered.append(handle)
                if selection.offer(handle: handle, filename: info.filename) { break }
            }
            tracker.markReviewed(offered)
            return selection.choice
        }

        /// The sharp review image bytes: the whole JPEG/HEIF, or a RAW's largest embedded
        /// JPEG preview. Nil when unavailable or when the calling task is cancelled.
        public func stillReviewImageData(
            for choice: NikonStillReviewSelection.Choice
        ) async -> Data? {
            guard let info = try? await getObjectInfo(handle: choice.handle) else { return nil }
            return await NikonStillReviewImageReader.read(
                kind: choice.kind, objectSize: info.compressedSize
            ) { offset, length in
                try await self.getPartialObject(
                    handle: choice.handle, offset: offset, length: length)
            }
        }

        private func stillReviewListing() async -> [UInt32: [UInt32]] {
            var listing: [UInt32: [UInt32]] = [:]
            for (storageID, _) in await readAllStorageInfo() {
                guard let handles = try? await getObjectHandles(storageID: storageID) else {
                    continue
                }
                listing[storageID] = handles
            }
            return listing
        }
    }
#endif
