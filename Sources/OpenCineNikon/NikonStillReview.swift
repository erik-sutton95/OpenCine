import Foundation

// Instant review of a just-captured still, shared by the iOS session
// (`NativeCameraSession+StillReview.swift`) and the Android facade
// (`OpenCineNikonAndroid/MediaBrowse.swift`). The shells only loop over
// ``NikonStillReviewPolicy/objectWindowMilliseconds`` and present what these
// types choose and read.

/// What a review shows for one captured card object.
public enum NikonStillReviewObjectKind: Equatable, Sendable {
    /// JPEG or HEIF: the camera's thumbnail first, then the image itself.
    case displayImage
    /// NEF or NRW: the largest JPEG preview embedded in the RAW file.
    case raw

    /// The kind for a card filename; nil for anything a still review cannot show.
    public init?(filename: String) {
        switch (filename as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "hif", "heif", "heic": self = .displayImage
        case "nef", "nrw": self = .raw
        default: return nil
        }
    }
}

/// Timing and size rules of the instant review.
public enum NikonStillReviewPolicy {
    /// How long after a completed release the shells keep looking for the shot's card object.
    /// A RAW+JPEG Fine* frame with heavier settings can take well over a second to land on the
    /// card; the previous fixed six tries 150 ms apart (under one second) missed it, so the
    /// review silently never appeared. [verify-on-HW: card write time per body and quality]
    public static let objectWindowMilliseconds = 4_000
    /// Pause between two lookups inside the window.
    public static let objectPollIntervalMilliseconds = 150
    /// `GetPartialObject` chunk for a whole JPEG/HEIF read; each chunk is one transaction, so
    /// live-view frames interleave between chunks on the shared channel.
    public static let fullImageChunkLength: UInt32 = 1_000_000
    /// Larger display images are not streamed for a review.
    public static let maximumFullImageBytes: UInt32 = 60_000_000
    /// Objects announced by `ObjectAdded` and not yet reviewed, kept at most.
    public static let maximumAnnouncedObjects = 64
}

/// Chooses the review object among the new objects of one capture, offered newest first.
///
/// A RAW+JPEG (or RAW+HEIF) shot adds two objects with the same file stem
/// (`DSC_0012.NEF`, `DSC_0012.JPG`); the display image wins because it needs no RAW parsing
/// and carries the rating property. A RAW-only shot reviews its NEF. Objects that belong to
/// an older shot (another stem) end the search, so a burst reviews only its last frame.
public struct NikonStillReviewSelection: Equatable, Sendable {
    /// The chosen object.
    public struct Choice: Equatable, Sendable {
        /// The card object handle.
        public let handle: UInt32
        /// The card filename.
        public let filename: String
        /// How the review reads it.
        public let kind: NikonStillReviewObjectKind
    }

    /// The best object offered so far.
    public private(set) var choice: Choice?
    private var shotStem: String?

    /// Creates an empty selection.
    public init() {}

    /// Offers one new object; call newest first. Returns true when an older object can no
    /// longer change the choice, so the caller can stop reading object info.
    public mutating func offer(handle: UInt32, filename: String) -> Bool {
        guard let kind = NikonStillReviewObjectKind(filename: filename) else { return false }
        let stem = (filename as NSString).deletingPathExtension.uppercased()
        guard let current = choice else {
            choice = Choice(handle: handle, filename: filename, kind: kind)
            shotStem = stem
            return kind == .displayImage
        }
        guard stem == shotStem else { return true }
        if current.kind == .raw, kind == .displayImage {
            choice = Choice(handle: handle, filename: filename, kind: kind)
        }
        return choice?.kind == .displayImage
    }
}

/// The card state a review diff runs against, plus the objects the camera announced.
///
/// `ObjectAdded` (`0x4002`) names the new object's handle in its first parameter, so a
/// review can go straight to it instead of listing every card. When no announcement arrived
/// (some channels or bodies may not send one), the review lists the cards and diffs them
/// against the baseline seeded before the capture. Handles a review already looked at are
/// remembered so a later diff never offers them again (that would review the previous photo).
///
/// Thread-safe: events are noted from the camera's event threads while a review reads it.
// SAFETY: all mutable state is guarded by `lock`.
public final class NikonStillReviewObjectTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var baseline: [UInt32: Set<UInt32>] = [:]
    private var announced: [UInt32] = []
    private var reviewed: Set<UInt32> = []

    /// Creates an empty tracker.
    public init() {}

    /// Whether a baseline was ever seeded or absorbed.
    public var hasBaseline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !baseline.isEmpty
    }

    /// Replaces the baseline with a fresh listing (storage ID to handles) and forgets older
    /// announcements, which all belong to objects already on the card.
    public func seed(listing: [UInt32: [UInt32]]) {
        lock.lock()
        defer { lock.unlock() }
        baseline = listing.mapValues(Set.init)
        announced.removeAll()
        reviewed.removeAll()
    }

    /// Notes the handle of an `ObjectAdded` event; other events are ignored.
    public func note(_ event: PTPEvent) {
        guard event.eventCode == .objectAdded, let handle = event.parameters.first, handle != 0
        else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !announced.contains(handle), !reviewed.contains(handle) else { return }
        announced.append(handle)
        if announced.count > NikonStillReviewPolicy.maximumAnnouncedObjects {
            announced.removeFirst(announced.count - NikonStillReviewPolicy.maximumAnnouncedObjects)
        }
    }

    /// Notes every `ObjectAdded` among `events`.
    public func note(_ events: [PTPEvent]) {
        for event in events { note(event) }
    }

    /// Takes the announced handles not yet reviewed, newest first.
    public func takeAnnounced() -> [UInt32] {
        lock.lock()
        defer { lock.unlock() }
        let taken = announced.sorted(by: >)
        announced.removeAll()
        return taken
    }

    /// Diffs a fresh listing against the baseline and makes it the new baseline for the
    /// storages it covers (a storage whose listing failed keeps its old baseline). Returns the
    /// new handles newest first. Without any earlier baseline the newest listed handle stands in,
    /// since nothing else can tell the new shot apart.
    public func absorb(listing: [UInt32: [UInt32]]) -> [UInt32] {
        lock.lock()
        defer { lock.unlock() }
        let hadBaseline = !baseline.isEmpty
        var fresh: Set<UInt32> = []
        var newest: UInt32 = 0
        for (storageID, handles) in listing {
            let current = Set(handles)
            if let known = baseline[storageID] {
                fresh.formUnion(current.subtracting(known))
            }
            newest = max(newest, current.max() ?? 0)
            baseline[storageID] = current
        }
        fresh.subtract(reviewed)
        reviewed.subtract(listing.values.joined())
        if fresh.isEmpty, !hadBaseline, newest > 0 { return [newest] }
        return fresh.sorted(by: >)
    }

    /// Remembers handles a review looked at, so a later diff does not offer them again.
    public func markReviewed(_ handles: [UInt32]) {
        lock.lock()
        defer { lock.unlock() }
        reviewed.formUnion(handles)
        announced.removeAll { reviewed.contains($0) }
    }
}

/// Reads the bytes a review decodes for its chosen object.
///
/// - JPEG/HEIF: the whole file in ``NikonStillReviewPolicy/fullImageChunkLength`` chunks.
/// - NEF/NRW: the head (``NikonRawPreviewLocator/defaultHeadLength``), then only the largest
///   embedded JPEG preview it names, tagged with the RAW's orientation. Nil when no preview
///   is found; the shell keeps the camera's own thumbnail.
///
/// The I/O stays with the caller's session through `readBytes(offset, length)`, so the same steps
/// run on the iOS async session and the Android blocking session.
public enum NikonStillReviewImageReader {
    /// Blocking variant; `isCancelled` is checked before every read.
    public static func read(
        kind: NikonStillReviewObjectKind,
        objectSize: UInt32,
        isCancelled: () -> Bool,
        readBytes: (UInt32, UInt32) throws -> Data
    ) -> Data? {
        switch kind {
        case .displayImage:
            guard isStreamable(objectSize) else { return nil }
            return readRange(
                offset: 0, length: objectSize, isCancelled: isCancelled, readBytes: readBytes)
        case .raw:
            guard objectSize > 0, !isCancelled(),
                let head = try? readBytes(0, headLength(objectSize)),
                let range = NikonRawPreviewLocator.largestPreview(
                    inHead: Array(head), objectSize: objectSize)
            else { return nil }
            return readRange(
                offset: range.offset, length: range.length, isCancelled: isCancelled,
                readBytes: readBytes
            ).map { NikonRawPreviewLocator.taggingOrientation($0, orientation: range.orientation) }
        }
    }

    /// Async variant for the iOS session; stops when the calling task is cancelled.
    public static func read(
        kind: NikonStillReviewObjectKind,
        objectSize: UInt32,
        readBytes: (UInt32, UInt32) async throws -> Data
    ) async -> Data? {
        switch kind {
        case .displayImage:
            guard isStreamable(objectSize) else { return nil }
            return await readRange(offset: 0, length: objectSize, readBytes: readBytes)
        case .raw:
            guard objectSize > 0, !Task.isCancelled,
                let head = try? await readBytes(0, headLength(objectSize)),
                let range = NikonRawPreviewLocator.largestPreview(
                    inHead: Array(head), objectSize: objectSize)
            else { return nil }
            let preview = await readRange(
                offset: range.offset, length: range.length, readBytes: readBytes)
            return preview.map {
                NikonRawPreviewLocator.taggingOrientation($0, orientation: range.orientation)
            }
        }
    }

    private static func isStreamable(_ size: UInt32) -> Bool {
        size > 0 && size < NikonStillReviewPolicy.maximumFullImageBytes
    }

    private static func headLength(_ objectSize: UInt32) -> UInt32 {
        min(NikonRawPreviewLocator.defaultHeadLength, objectSize)
    }

    private static func chunkLength(from offset: UInt64, to end: UInt64) -> UInt32 {
        UInt32(min(UInt64(NikonStillReviewPolicy.fullImageChunkLength), end - offset))
    }

    private static func readRange(
        offset start: UInt32, length: UInt32, isCancelled: () -> Bool,
        readBytes: (UInt32, UInt32) throws -> Data
    ) -> Data? {
        var data = Data()
        data.reserveCapacity(Int(length))
        let end = UInt64(start) + UInt64(length)
        var offset = UInt64(start)
        while offset < end {
            guard !isCancelled() else { return nil }
            let chunk = chunkLength(from: offset, to: end)
            guard let part = try? readBytes(UInt32(offset), chunk), !part.isEmpty else {
                return nil
            }
            data.append(part.prefix(Int(chunk)))
            offset += UInt64(min(part.count, Int(chunk)))
        }
        return data
    }

    private static func readRange(
        offset start: UInt32, length: UInt32,
        readBytes: (UInt32, UInt32) async throws -> Data
    ) async -> Data? {
        var data = Data()
        data.reserveCapacity(Int(length))
        let end = UInt64(start) + UInt64(length)
        var offset = UInt64(start)
        while offset < end {
            guard !Task.isCancelled else { return nil }
            let chunk = chunkLength(from: offset, to: end)
            guard let part = try? await readBytes(UInt32(offset), chunk), !part.isEmpty else {
                return nil
            }
            data.append(part.prefix(Int(chunk)))
            offset += UInt64(min(part.count, Int(chunk)))
        }
        return data
    }
}

/// How a shell reacts to a capture event it did not ask for (`ObjectAdded` or capture complete).
public enum NikonBodyCaptureSync: Equatable, Sendable {
    /// Movie mode, the app's own release, or one more event of a run already synced.
    case ignore
    /// Photo mode without instant review: refresh the remaining-shots readout only.
    case shotsOnly
    /// Photo mode with instant review: review the shot and refresh the remaining shots.
    case reviewAndShots
}

/// Tells a shot fired on the body apart from the late card objects of the app's own release.
///
/// The app's release completes before all of its objects reach the card: the second half of a
/// RAW+JPEG pair, or a burst's later frames, are announced after it. Those events used to count as
/// a shot fired on the body, and the review that followed cancelled the app's own review while it
/// read the sharp image, leaving the blurred thumb on screen for good. So every event within
/// ``NikonStillReviewPolicy/objectWindowMilliseconds`` of the app's release, or of the previous
/// late object, belongs to that release. A real body run is synced once, then quiet for
/// ``bodyRunDebounceMilliseconds`` after each of its events.
///
/// Times are any monotonic clock in milliseconds. Kotlin twin:
/// `com.opencapture.opencine.nikon.NikonBodyCaptureFilter`. [verify-on-HW: object arrival after a
/// RAW+JPEG release per body]
public struct NikonBodyCaptureFilter: Equatable, Sendable {
    /// Quiet period after a synced body capture, so one body burst syncs once.
    public static let bodyRunDebounceMilliseconds: Int64 = 800

    private var appReleaseTailUntil: Int64?
    private var bodyRunQuietUntil: Int64?

    /// Creates a filter that has seen no capture yet.
    public init() {}

    /// The app's own release run completed at `now`.
    public mutating func appReleaseCompleted(at now: Int64) {
        appReleaseTailUntil = now + Int64(NikonStillReviewPolicy.objectWindowMilliseconds)
    }

    /// Classifies one capture event at `now`.
    public mutating func action(
        at now: Int64, isPhotography: Bool, instantReviewEnabled: Bool, appReleaseInFlight: Bool
    ) -> NikonBodyCaptureSync {
        guard isPhotography else { return .ignore }
        if appReleaseInFlight {
            return .ignore
        }
        if let until = appReleaseTailUntil, now < until {
            appReleaseTailUntil = now + Int64(NikonStillReviewPolicy.objectWindowMilliseconds)
            return .ignore
        }
        appReleaseTailUntil = nil
        if let until = bodyRunQuietUntil, now < until {
            bodyRunQuietUntil = now + Self.bodyRunDebounceMilliseconds
            return .ignore
        }
        bodyRunQuietUntil = now + Self.bodyRunDebounceMilliseconds
        return instantReviewEnabled ? .reviewAndShots : .shotsOnly
    }
}
