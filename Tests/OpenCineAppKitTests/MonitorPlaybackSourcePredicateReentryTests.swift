import Foundation
import OpenCineAppKit
import OpenCineCore
import OpenCineMedia
import Testing

// SIMULATED: manual-clock source reentry through the actual shared playback owner.
@MainActor private final class SourceReentryCodec: MonitorMediaCatalogCodec {
  typealias Payload = String
  let records: [MonitorMediaRecord<String>]
  init(_ records: [MonitorMediaRecord<String>]) { self.records = records }
  func decode(_ bytes: Data) -> [MonitorMediaRecord<String>] { records }
  func encode(_ records: [MonitorMediaRecord<String>]) -> Data { Data([1]) }
  func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) throws -> MonitorMediaRecord<String> {
    throw MediaServiceError.unsupported
  }
}

@MainActor private final class SourceReentryFavorites: MonitorMediaFavoritesStore {
  func favorites() -> Set<String> { [] }
  func saveFavorites(_ keys: Set<String>) {}
}

@MainActor private final class SourceReentryPort: MonitorPlaybackPort {
  var onEvent: (@MainActor @Sendable (MonitorPlaybackItemToken, MonitorPlaybackEvent) -> Void)?
  var prepared: [MonitorPlaybackItemToken] = []
  var closed: [MonitorPlaybackItemToken] = []
  func retireItem(for token: MonitorPlaybackItemToken) {}
  func prepare(_ item: MonitorPlaybackItem, token: MonitorPlaybackItemToken,
    readyTimeout: Duration?) async throws -> MonitorPlaybackMetadata {
    prepared.append(token)
    onEvent?(token, .itemInstalled)
    return .init(duration: 8, conform: .init(captureRate: 60))
  }
  func play(rate: Double, token: MonitorPlaybackItemToken) {}
  func pause(token: MonitorPlaybackItemToken) {}
  func seek(seconds: Double, tolerance: Double, token: MonitorPlaybackItemToken) async -> Bool { true }
  func setMuted(_ muted: Bool, token: MonitorPlaybackItemToken) {}
  func close(token: MonitorPlaybackItemToken) { closed.append(token) }
}

@MainActor @Suite struct MonitorPlaybackSourcePredicateReentryTests {
  @available(macOS 14, *) @MainActor private final class Fixture {
    let root: URL
    let records: [MonitorMediaRecord<String>]
    let library: MonitorMediaLibraryModel<String>
    let port = SourceReentryPort()
    var instant = MonotonicInstant(.seconds(100))
    var predicate: (@MainActor @Sendable (String) -> Bool)?
    var replacementArmed = false
    var replacementReply = true
    var replacementCalls = 0
    var refusalCalls = 0
    lazy var model = MonitorMediaPlaybackModel<String, String>(library: library, native: port,
      candidates: { [.cached(.init(url: URL(fileURLWithPath: "/" + $0.payload + ".mov"),
        mimeType: "video/mp4", sourceKey: $0.payload))] }, now: { [unowned self] in instant })

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      records = ["A", "B"].map { id in
        .init(asset: .init(id: .init(id), filename: id + ".mov", kind: .video,
          representations: [], deletable: true), payload: id,
          address: .init(thumbnail: nil, representations: [:], favoriteKey: id))
      }
      let directory = MonitorMediaCacheDirectory(root: root)
      try directory.write(Data([1]), at: "index.json")
      library = MonitorMediaLibraryModel(cache: MonitorMediaCache(directory: directory,
        codec: SourceReentryCodec(records), eligibility: .exactSize, catalogAddress: "index.json",
        preservedMetadata: ["index.json"]), favorites: SourceReentryFavorites())
      library.visibility = .allRecords
      library.begin()
      model.setItemAdmission { [weak self] record in
        .init { [weak self] in self?.predicate?(record.payload) ?? true }
      }
    }

    func loadFirst() { model.load(records[0], playlist: records, play: false) }
    func armReplacement(returning reply: Bool) {
      replacementArmed = true
      replacementReply = reply
      predicate = { [weak self] payload in
        guard let self, payload == "A", replacementArmed else { return true }
        replacementArmed = false
        replacementCalls += 1
        model.load(records[1], playlist: records, play: false)
        return replacementReply
      }
    }
    func close() { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
  }

  private func settled(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<300 { if predicate() { return true }; await Task.yield() }
    return predicate()
  }

  @Test func predicateReplacementRejectsFalseAndTrueNativePosition() async throws {
    guard #available(macOS 14, *) else { return }
    for reply in [false, true] {
      let f = try Fixture(); defer { f.close() }
      f.loadFirst(); #expect(await settled { f.model.ready })
      let old = f.model.token
      f.armReplacement(returning: reply)
      f.port.onEvent?(old, .position(42))
      #expect(f.replacementCalls == 1 && f.model.token != old && f.model.active?.payload == "B")
      #expect(f.model.position == 0 && !f.model.closed && f.port.closed.isEmpty)
      #expect(await settled { f.model.ready })
      f.port.onEvent?(old, .position(55))
      #expect(f.model.position == 0 && f.library.browsing)
    }
  }

  @Test func predicateReplacementRejectsFalseAndTrueNativeFailure() async throws {
    guard #available(macOS 14, *) else { return }
    for reply in [false, true] {
      let f = try Fixture(); defer { f.close() }
      f.loadFirst(); #expect(await settled { f.model.ready })
      let old = f.model.token
      f.armReplacement(returning: reply)
      f.port.onEvent?(old, .failed("retired item"))
      #expect(f.model.token != old && f.model.active?.payload == "B")
      #expect(f.model.error == nil && f.model.loading && !f.model.closed && f.port.closed.isEmpty)
      #expect(await settled { f.model.ready })
      #expect(f.model.error == nil && f.model.ready)
    }
  }

  @Test func predicateReplacementCannotApplyOldLoopMutation() async throws {
    guard #available(macOS 14, *) else { return }
    for reply in [false, true] {
      let f = try Fixture(); defer { f.close() }
      f.loadFirst(); #expect(await settled { f.model.ready })
      let old = f.model.token
      f.armReplacement(returning: reply)
      f.model.setLooping(true)
      #expect(f.model.token != old && f.model.active?.payload == "B")
      #expect(!f.model.looping && !f.model.closed && f.port.closed.isEmpty)
    }
  }

  @Test func predicateReplacementCannotApplyOldMutedMutation() async throws {
    guard #available(macOS 14, *) else { return }
    for reply in [false, true] {
      let f = try Fixture(); defer { f.close() }
      f.loadFirst(); #expect(await settled { f.model.ready })
      let old = f.model.token
      f.armReplacement(returning: reply)
      f.model.setMuted(true)
      #expect(f.model.token != old && f.model.active?.payload == "B")
      #expect(!f.model.muted && !f.model.closed && f.port.closed.isEmpty)
    }
  }

  @Test func refusalDoesNotReevaluateIntoAndCloseSuccessor() async throws {
    guard #available(macOS 14, *) else { return }
    let f = try Fixture(); defer { f.close() }
    f.loadFirst(); #expect(await settled { f.model.ready })
    let old = f.model.token
    f.predicate = { [weak f] payload in
      guard let f, payload == "A" else { return true }
      f.refusalCalls += 1
      if f.refusalCalls == 1 { return false }
      if f.refusalCalls == 2 {
        f.model.load(f.records[1], playlist: f.records, play: false)
        return false
      }
      return true
    }
    f.model.setLooping(true)
    #expect(f.refusalCalls == 1 && f.model.active?.payload == "A" && f.model.closed)
    #expect(!f.model.looping && f.model.token.owner == old.owner && f.model.token.revision == old.revision + 1)
    #expect(f.port.closed == [f.model.token] && f.port.prepared == [old] && f.library.browsing)
  }

  @Test func sameCurrentPredicateAllowsPositionAndLoop() async throws {
    guard #available(macOS 14, *) else { return }
    let f = try Fixture(); defer { f.close() }
    f.loadFirst(); #expect(await settled { f.model.ready })
    let token = f.model.token
    f.predicate = { _ in true }
    f.port.onEvent?(token, .position(3))
    f.model.setLooping(true)
    #expect(f.model.position == 3 && f.model.looping && f.model.token == token)
    #expect(!f.model.closed && f.port.closed.isEmpty)
  }

  @Test func sameCurrentRefusalClosesOnlyCapturedOwner() async throws {
    guard #available(macOS 14, *) else { return }
    let f = try Fixture(); defer { f.close() }
    f.loadFirst(); #expect(await settled { f.model.ready })
    let old = f.model.token
    f.predicate = { _ in false }
    f.port.onEvent?(old, .position(4))
    #expect(f.model.closed && f.model.position == 0 && f.model.active?.payload == "A")
    #expect(f.model.token.owner == old.owner && f.model.token.revision == old.revision + 1)
    #expect(f.port.closed == [f.model.token] && f.library.browsing)
  }
}
