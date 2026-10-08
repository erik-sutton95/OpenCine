import Foundation
import Observation
import OpenCineAppKit
import OpenCineMedia
import Testing

@MainActor private final class RatingReentryCodec: MonitorMediaCatalogCodec {
    typealias Payload = String
    let record: MonitorMediaRecord<String>
    init(_ record: MonitorMediaRecord<String>) { self.record = record }
    func decode(_ bytes: Data) -> [MonitorMediaRecord<String>] { [record] }
    func encode(_ records: [MonitorMediaRecord<String>]) -> Data { Data([1]) }
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) throws -> MonitorMediaRecord<String> {
        throw MediaServiceError.unsupported
    }
}

@MainActor private final class RatingReentryFavorites: MonitorMediaFavoritesStore {
    func favorites() -> Set<String> { [] }
    func saveFavorites(_ keys: Set<String>) {}
}

@MainActor private final class RatingReentryPort: MonitorPlaybackPort {
    var onEvent: (@MainActor @Sendable (MonitorPlaybackItemToken, MonitorPlaybackEvent) -> Void)?
    func retireItem(for token: MonitorPlaybackItemToken) {}
    func prepare(_ item: MonitorPlaybackItem, token: MonitorPlaybackItemToken,
        readyTimeout: Duration?) async throws -> MonitorPlaybackMetadata {
        onEvent?(token, .itemInstalled)
        return .init(duration: 8)
    }
    func play(rate: Double, token: MonitorPlaybackItemToken) {}
    func pause(token: MonitorPlaybackItemToken) {}
    func seek(seconds: Double, tolerance: Double, token: MonitorPlaybackItemToken) async -> Bool { true }
    func setMuted(_ muted: Bool, token: MonitorPlaybackItemToken) {}
    func close(token: MonitorPlaybackItemToken) {}
}

@MainActor private final class RatingReentryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    var entered = false
    func wait() async {
        entered = true
        if finished { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        finished = true
        let outgoing = continuation; continuation = nil
        outgoing?.resume()
    }
}

@available(macOS 14, *) @MainActor private final class RatingReentryFixture {
    let root: URL
    let record: MonitorMediaRecord<String>
    let library: MonitorMediaLibraryModel<String>
    let successor = RatingReentryGate()
    var clocks: [RatingReentryGate] = []
    var reads = 0
    var writes: [Int] = []
    var completion: MonitorMediaPictureRatingResult = .refused("Outgoing refusal")
    var afterCommit: (@MainActor () -> Void)?
    var onPredicate: (@MainActor () -> Bool)?
    lazy var service = MonitorMediaPlaybackRatingService<String>(levels: [1, 2, 3, 4],
        unavailableMessage: "Outgoing unavailable",
        read: { [unowned self] _ in reads += 1; return 2 },
        commit: { [unowned self] target, _ in
            writes.append(target)
            if target == 1 { return .refused("Existing notice") }
            if target == 4 { await successor.wait(); return .confirmed(4) }
            afterCommit?()
            return completion
        })
    lazy var model = MonitorOperatorMediaModel<String, String>(library: library,
        recordAdmission: { [unowned self] _ in .init { [weak self] in self?.onPredicate?() ?? true } },
        sleep: { [unowned self] duration in
            #expect(duration == .seconds(4))
            let gate = RatingReentryGate(); clocks.append(gate); await gate.wait()
        }, makePlayback: { library in
            MonitorMediaPlaybackModel<String, String>(library: library, native: RatingReentryPort(),
                candidates: { [.cached(.init(url: URL(fileURLWithPath: "/" + $0.payload + ".mov"),
                    mimeType: "video/mp4", sourceKey: $0.payload))] })
        })
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        record = .init(asset: .init(id: .init("A"), filename: "A.mov", kind: .video,
            representations: [], deletable: true), payload: "A",
            address: .init(thumbnail: nil, representations: [:], favoriteKey: "A"))
        let directory = MonitorMediaCacheDirectory(root: root)
        try directory.write(Data([1]), at: "index.json")
        library = MonitorMediaLibraryModel(cache: MonitorMediaCache(directory: directory,
            codec: RatingReentryCodec(record), eligibility: .exactSize, catalogAddress: "index.json",
            preservedMetadata: ["index.json"]), favorites: RatingReentryFavorites())
        library.visibility = .allRecords; library.begin()
    }
    func open() -> Bool { model.open(record, playlist: [record], admitted: library.actionToken) }
    func close() {
        onPredicate = nil; afterCommit = nil
        model.closePlayback(); library.close()
        successor.finish(); clocks.forEach { $0.finish() }
        try? FileManager.default.removeItem(at: root)
    }
    func replaceRating(when condition: @escaping @MainActor () -> Bool = { true }, reply: Bool) {
        onPredicate = { [weak self] in
            guard let self else { return false }
            guard condition() else { return true }
            onPredicate = nil
            model.setRating(4, service: service)
            return reply
        }
    }
}

@MainActor @Suite struct MonitorOperatorRatingReentryTests {
    private func settled(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<500 { if predicate() { return true }; await Task.yield() }
        return predicate()
    }
    @available(macOS 14, *) private func seedNotice(_ fixture: RatingReentryFixture) async throws {
        let opened = fixture.open(); try #require(opened)
        fixture.model.readRating(fixture.service)
        let read = await settled { fixture.reads == 1 && fixture.model.ratingStars == 2 }
        try #require(read)
        fixture.model.setRating(1, service: fixture.service)
        let published = await settled { fixture.clocks.count == 1 && !fixture.model.ratingPending }
        try #require(published)
        #expect(fixture.model.ratingNotice == "Existing notice")
    }

    @Test func predicateReplacementDuringRequestCannotStartOldRating() async throws {
        guard #available(macOS 14, *) else { return }
        for reply in [false, true] {
            let f = try RatingReentryFixture(); defer { f.close() }
            let opened = f.open(); try #require(opened)
            let token = try #require(f.model.playback?.token)
            f.replaceRating(reply: reply)
            f.model.setRating(3, service: f.service)
            let entered = await settled { f.successor.entered }; try #require(entered)
            #expect(f.writes == [4] && f.model.ratingStars == 4 && f.model.ratingPending)
            #expect(f.model.playback?.token == token && f.clocks.isEmpty)
            f.successor.finish()
            let finished = await settled { !f.model.ratingPending }; #expect(finished)
            #expect(f.model.ratingStars == 4)
        }
    }

    @Test func predicateReplacementDuringReadRequestCannotPublishOldRating() async throws {
        guard #available(macOS 14, *) else { return }
        for reply in [false, true] {
            let f = try RatingReentryFixture(); defer { f.close() }
            let opened = f.open(); try #require(opened)
            f.replaceRating(reply: reply)
            f.model.readRating(f.service)
            let entered = await settled { f.successor.entered }; try #require(entered)
            #expect(f.reads == 0 && f.writes == [4] && f.model.ratingStars == 4 && f.model.ratingPending)
        }
    }

    @Test func predicateReplacementDuringCompletionPreservesSameItemSuccessor() async throws {
        guard #available(macOS 14, *) else { return }
        let outcomes: [MonitorMediaPictureRatingResult] = [.confirmed(2), .refused("Outgoing refusal"), .unavailable]
        for outcome in outcomes { for reply in [false, true] {
            let f = try RatingReentryFixture(); defer { f.close() }
            try await seedNotice(f)
            let token = try #require(f.model.playback?.token)
            f.completion = outcome
            f.afterCommit = { [unowned f] in
                f.replaceRating(when: { f.model.ratingStars == 2 }, reply: reply)
            }
            f.model.setRating(3, service: f.service)
            let entered = await settled { f.successor.entered }; try #require(entered)
            #expect(f.writes == [1, 3, 4] && f.model.playback?.token == token)
            #expect(f.model.ratingStars == 4 && f.model.ratingPending)
            #expect(f.model.ratingNotice == "Existing notice" && f.clocks.count == 1)
            f.successor.finish()
            let finished = await settled { !f.model.ratingPending }; #expect(finished)
            #expect(f.model.ratingStars == 4 && f.model.ratingNotice == nil)
        } }
    }

    @Test func predicateReplacementDuringNoticeCreationCannotPublishOldNotice() async throws {
        guard #available(macOS 14, *) else { return }
        for reply in [false, true] {
            let f = try RatingReentryFixture(); defer { f.close() }; try await seedNotice(f)
            f.afterCommit = { [unowned f] in
                f.replaceRating(when: { f.model.ratingNotice == nil }, reply: reply)
            }
            f.model.setRating(3, service: f.service)
            let entered = await settled { f.successor.entered }; try #require(entered)
            #expect(f.model.ratingStars == 4 && f.model.ratingPending)
            #expect(f.model.ratingNotice == nil && f.clocks.count == 1)
        }
    }

    @Test func predicateReplacementDuringNoticeExpiryCannotClearSuccessor() async throws {
        guard #available(macOS 14, *) else { return }
        for reply in [false, true] {
            let f = try RatingReentryFixture(); defer { f.close() }; try await seedNotice(f)
            f.replaceRating(reply: reply)
            f.clocks[0].finish()
            let entered = await settled { f.successor.entered }; try #require(entered)
            #expect(f.model.ratingNotice == "Existing notice" && f.model.ratingStars == 4 && f.model.ratingPending)
            #expect(f.clocks.count == 1 && f.writes == [1, 4])
        }
    }

    @Test func noticePublicationReplacementCannotScheduleOldExpiry() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try RatingReentryFixture(); defer { f.close() }; try await seedNotice(f)
        f.afterCommit = { [unowned f] in
            f.onPredicate = { [weak f] in
                guard let f else { return false }
                guard f.model.ratingNotice == nil else { return true }
                f.onPredicate = nil
                withObservationTracking { _ = f.model.ratingNotice } onChange: {
                    MainActor.assumeIsolated { f.model.setRating(4, service: f.service) }
                }
                return true
            }
        }
        f.model.setRating(3, service: f.service)
        let entered = await settled { f.successor.entered }; try #require(entered)
        #expect(f.model.ratingNotice == "Outgoing refusal" && f.model.ratingStars == 4 && f.model.ratingPending)
        #expect(f.clocks.count == 1 && f.writes == [1, 3, 4])
    }

    @Test func currentRatingAndManualNoticeExpiryKeepOriginalBehavior() async throws {
        guard #available(macOS 14, *) else { return }
        let f = try RatingReentryFixture(); defer { f.close() }; try await seedNotice(f)
        f.clocks[0].finish()
        let cleared = await settled { f.model.ratingNotice == nil }; #expect(cleared)
        f.completion = .confirmed(3)
        f.model.setRating(3, service: f.service)
        let finished = await settled { !f.model.ratingPending }; #expect(finished)
        #expect(f.model.ratingStars == 3 && f.model.ratingNotice == nil && f.writes == [1, 3])
    }
}
