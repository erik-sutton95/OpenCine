#if os(iOS)
import AVFoundation
import Foundation
import Observation
import OpenCineAppKit
import OpenCineMedia
import XCTest
@testable import OpenCineApple
@testable import OpenCineAppKitApple

/// SIMULATED frame sources. The native player, feed, audio tap and item callbacks are real; no
/// camera, network, permission or system audio session is used.
@MainActor final class MonitorPlaybackFrameSourceTests: XCTestCase {
    /// An integration source with its own file lifetime drives the same assist session the
    /// plain file owner does: attach on install, detach from that exact item on retirement.
    func testAssistSessionAttachesAndDetachesThroughAnyFrameSource() async throws {
        let tone = try Self.tone()
        defer { try? FileManager.default.removeItem(at: tone.deletingLastPathComponent()) }
        let source = SimulatedFrameSource()
        let session = MonitorPlaybackAssistSession(audioSession: Self.silentAudio(),
            native: source, samples: LiveFrameSampleBus())
        defer { session.close() }
        let token = MonitorPlaybackItemToken(owner: UUID(), revision: 0)
        let item = AVPlayerItem(url: tone)
        source.install(item)
        session.synchronize(item: token, effects: .init(), audioVisible: true, outputMuted: true,
            ifCurrent: { true })
        try await Self.waitUntil { item.audioMix != nil }
        source.retire()
        XCTAssertNil(item.audioMix, "the retired item keeps no tap after the source reports it gone")
        XCTAssertNil(session.audioLevels)
    }

    /// The plain file owner reports its retirement after the item left the player; the session
    /// must still remove the tap from the item it attached to.
    func testRetiredAppleOwnerItemLosesItsAudioTap() async throws {
        let tone = try Self.tone()
        defer { try? FileManager.default.removeItem(at: tone.deletingLastPathComponent()) }
        let native = MonitorApplePlaybackOwner(feed: MonitorPlaybackFeedSession(
            configuration: .init(), hdrDisplay: { false }))
        let session = MonitorPlaybackAssistSession(audioSession: Self.silentAudio(),
            native: native, samples: LiveFrameSampleBus())
        let token = MonitorPlaybackItemToken(owner: UUID(), revision: 0)
        defer { session.close(); native.close(token: token) }
        native.retireItem(for: token)
        _ = try await native.prepare(.init(url: tone, mimeType: "audio/x-caf",
            sourceKey: "SIMULATED-tone"), token: token, readyTimeout: .seconds(8))
        let item = try XCTUnwrap(native.player.currentItem)
        session.synchronize(item: token, effects: .init(), audioVisible: true, outputMuted: true,
            ifCurrent: { true })
        try await Self.waitUntil { item.audioMix != nil }
        native.retireItem(for: .init(owner: token.owner, revision: 1))
        XCTAssertNil(item.audioMix, "the retired item keeps no tap")
    }

    /// A host that publishes who owns the audio session hears it from the shared lease.
    func testAudioOwnershipFollowsTheSharedLease() async {
        let audio = Self.silentAudio()
        let owned = OwnershipLog()
        let session = MonitorPlaybackAssistSession(audioSession: audio, native: SimulatedFrameSource(),
            samples: LiveFrameSampleBus(), audioOwnership: { owned.values.append($0) })
        session.activate()
        XCTAssertEqual(owned.values, [true])
        session.close()
        await audio.finishPendingWork()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while owned.values.count < 2, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(owned.values, [true, false])
    }

    /// The page runtime installs the source's own frame source for each admitted item, on the
    /// feed the page made, and binds the assists to it.
    func testPresentationInstallsTheSourcesFrameSourceForEachAdmittedItem() throws {
        let fixture = try LibraryFixture()
        defer { fixture.close() }
        var feeds: [MonitorPlaybackFeedSession] = []
        var sources: [SimulatedFrameSource] = []
        let presentation = MonitorApplePlaybackPresentation<String, String>(
            makeFeed: {
                let feed = MonitorPlaybackFeedSession(configuration: .init(), hdrDisplay: { false })
                feeds.append(feed)
                return feed
            }, audioSession: Self.silentAudio(), samples: { LiveFrameSampleBus() })
        let owner = presentation.makeOwner(library: fixture.library,
            recordAdmission: { _ in .init { true } },
            makeNative: { feed -> SimulatedFrameSource in
                let source = SimulatedFrameSource(feed: feed)
                sources.append(source)
                return source
            }, makePlayback: { native in
                MonitorMediaPlaybackModel<String, String>(library: fixture.library, native: native,
                    candidates: { _ in [.cached(.init(url: fixture.file, mimeType: "video/mp4",
                        sourceKey: "SIMULATED"))] })
            })
        defer { owner.closePlayback() }
        XCTAssertTrue(owner.open(fixture.record, playlist: [fixture.record],
            admitted: fixture.library.actionToken))
        let source = try XCTUnwrap(sources.first)
        XCTAssertTrue(presentation.native === source)
        XCTAssertTrue(source.feed === feeds.first)
        XCTAssertNotNil(presentation.assists)
        XCTAssertTrue(owner.playback?.native === source)
    }

    /// An observer that reacts to the published source by opening a successor cannot have the
    /// outgoing installation overwrite the successor's assists.
    func testPublicationReentryCannotReplaceTheSuccessorAssists() throws {
        let fixture = try LibraryFixture()
        defer { fixture.close() }
        let presentation = MonitorApplePlaybackPresentation<String, String>(
            makeFeed: { MonitorPlaybackFeedSession(configuration: .init(), hdrDisplay: { false }) },
            audioSession: Self.silentAudio(), samples: { LiveFrameSampleBus() })
        var made: [SimulatedFrameSource] = []
        let owner = presentation.makeOwner(library: fixture.library,
            recordAdmission: { _ in .init { true } },
            makeNative: { feed -> SimulatedFrameSource in
                let source = SimulatedFrameSource(feed: feed)
                made.append(source)
                return source
            }, makePlayback: { native in
                MonitorMediaPlaybackModel<String, String>(library: fixture.library, native: native,
                    candidates: { _ in [.cached(.init(url: fixture.file, mimeType: "video/mp4",
                        sourceKey: "SIMULATED"))] })
            })
        defer { owner.closePlayback() }
        let reentry = Reentry {
            _ = owner.open(fixture.record, playlist: [fixture.record], admitted: fixture.library.actionToken)
        }
        withObservationTracking { _ = presentation.native } onChange: {
            MainActor.assumeIsolated { reentry.fireOnce() }
        }
        reentry.open()
        XCTAssertTrue(reentry.done)
        let successor = try XCTUnwrap(made.last)
        XCTAssertEqual(made.count, 2)
        XCTAssertTrue(presentation.native === successor, "the successor's source stays installed")
        XCTAssertNotNil(presentation.assists)
        XCTAssertTrue(owner.playback?.native === successor)
    }

    private static func silentAudio() -> MonitorPlaybackAudioSession {
        MonitorPlaybackAudioSession(operations: .init(configure: {}, setActive: { _ in }))
    }

    private static func tone() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SIMULATED-frame-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("tone.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = buffer.frameCapacity
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<Int(buffer.frameLength) {
            let value = 0.5 * sin(Float(frame) * 2 * .pi * 440 / 48_000)
            channels[0][frame] = value
            channels[1][frame] = value
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("SIMULATED native deadline expired")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor private final class OwnershipLog { var values: [Bool] = [] }
@MainActor private final class Reentry {
    private(set) var done = false
    let open: @MainActor () -> Void
    init(open: @escaping @MainActor () -> Void) { self.open = open }
    func fireOnce() {
        guard !done else { return }
        done = true
        open()
    }
}

/// A SIMULATED integration source: it installs items itself and reports them like a camera
/// cache source would, over a real player and the shared feed.
@MainActor private final class SimulatedFrameSource: MonitorPlaybackFrameSource {
    let player = AVPlayer()
    let feed: MonitorPlaybackFeedSession
    var onEvent: (@MainActor @Sendable (MonitorPlaybackItemToken, MonitorPlaybackEvent) -> Void)?
    var onItemChanged: (@MainActor (AVPlayerItem?) -> Void)?
    init(feed: MonitorPlaybackFeedSession = MonitorPlaybackFeedSession(
        configuration: .init(), hdrDisplay: { false })) {
        self.feed = feed
    }
    func install(_ item: AVPlayerItem) {
        feed.prepare(item)
        player.replaceCurrentItem(with: item)
        onItemChanged?(item)
    }
    func retire() {
        onItemChanged?(nil)
        feed.beginSourceChange()
        player.replaceCurrentItem(with: nil)
    }
    func retireItem(for token: MonitorPlaybackItemToken) {}
    func prepare(_ item: MonitorPlaybackItem, token: MonitorPlaybackItemToken,
        readyTimeout: Duration?) async throws -> MonitorPlaybackMetadata {
        .init(duration: 1, width: 16, height: 9)
    }
    func play(rate: Double, token: MonitorPlaybackItemToken) {}
    func pause(token: MonitorPlaybackItemToken) {}
    func seek(seconds: Double, tolerance: Double, token: MonitorPlaybackItemToken) async -> Bool { true }
    func setMuted(_ muted: Bool, token: MonitorPlaybackItemToken) {}
    func close(token: MonitorPlaybackItemToken) { feed.shutdown() }
    func bufferedThroughSeconds(token: MonitorPlaybackItemToken) -> Double? { nil }
}

/// One SIMULATED cached clip in a real media library.
@MainActor private final class LibraryFixture {
    let root: URL
    let file: URL
    let record: MonitorMediaRecord<String>
    let library: MonitorMediaLibraryModel<String>

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SIMULATED.frame-source." + UUID().uuidString)
        let directory = MonitorMediaCacheDirectory(root: root)
        record = MonitorMediaRecord<String>(
            asset: .init(id: .init("SIMULATED-clip"), filename: "SIMULATED-clip.mov", kind: .video,
                representations: [.init(id: .init("SIMULATED-original"), role: .original, byteCount: 1)]),
            payload: "SIMULATED-clip",
            address: .init(thumbnail: nil,
                representations: [.init("SIMULATED-original"): "SIMULATED-clip.mov"],
                favoriteKey: "SIMULATED-clip"))
        try directory.write(Data([1]), at: "index.json")
        try directory.write(Data([1]), at: "SIMULATED-clip.mov")
        file = root.appendingPathComponent("SIMULATED-clip.mov")
        library = MonitorMediaLibraryModel(
            cache: .init(directory: directory, codec: FixtureCodec([record]),
                eligibility: .exactSize, catalogAddress: "index.json", preservedMetadata: ["index.json"]),
            favorites: FixtureFavorites())
        library.visibility = .allRecords
        library.begin()
    }

    func close() {
        library.close()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor private final class FixtureCodec: MonitorMediaCatalogCodec {
    typealias Payload = String
    let values: [MonitorMediaRecord<String>]
    init(_ values: [MonitorMediaRecord<String>]) { self.values = values }
    func decode(_ bytes: Data) -> [MonitorMediaRecord<String>] { values }
    func encode(_ records: [MonitorMediaRecord<String>]) -> Data { Data([1]) }
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) throws -> MonitorMediaRecord<String> {
        throw MediaServiceError.unsupported
    }
}

@MainActor private final class FixtureFavorites: MonitorMediaFavoritesStore {
    func favorites() -> Set<String> { [] }
    func saveFavorites(_ keys: Set<String>) {}
}
#endif
