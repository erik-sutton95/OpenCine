import Foundation
import Observation
import OpenCineCore
import OpenCineMedia

/// Immutable source choices. The model, not a source adapter, owns preparation and cache writes.
public enum MonitorPlaybackCandidate: Sendable {
  case cached(MonitorPlaybackItem)
  /// Explicit host IO independent of an optional camera transfer service. Captured admission
  /// supplies actual source authority; the model retains item, content and directory ownership.
  case hostDownload(
    address: String, mimeType: String, sourceKey: String,
    role: MediaRepresentationRole, admission: MonitorPlaybackAdmission,
    didCommit: @MainActor @Sendable () -> Void = {},
    transfer: @MainActor @Sendable (any MediaByteSink) async throws -> MediaTransferReceipt)
  case representation(MediaRepresentationID, mimeType: String, sourceKey: String)
  case download(
    address: String, mimeType: String, sourceKey: String,
    role: MediaRepresentationRole,
    transfer: @MainActor @Sendable (any MediaByteSink) async throws -> MediaTransferReceipt)
}

/// A captured predicate, not a source observation or permission synthesized by the player.
public struct MonitorPlaybackAdmission: Sendable {
  public let isCurrent: @MainActor @Sendable () -> Bool
  public init(isCurrent: @escaping @MainActor @Sendable () -> Bool) { self.isCurrent = isCurrent }
}

/// Neutral transfer and source-owned immutable look facts accepted for one item/request.
public struct MonitorPlaybackLook<Source: Sendable>: Sendable {
  public let transfer: MonitorTransfer?
  public let source: Source
  public init(transfer: MonitorTransfer?, source: Source) {
    self.transfer = transfer
    self.source = source
  }
}

/// One real video-player owner borrowing its gallery. Native item and pointer callbacks are
/// admitted against the same revision before they may affect transport, time, look or cleanup.
@available(macOS 14, *) @MainActor @Observable
public final class MonitorMediaPlaybackModel<Payload: Sendable, Look: Sendable> {
  // Commit authoritative state before notifying observers. A synchronous callback can replace
  // the item without an outgoing setter writing its old value over the successor.
  private struct Snapshot {
    var active: MonitorMediaRecord<Payload>? = nil
    var playlist: [MonitorMediaRecord<Payload>] = []
    /// `active`'s place in `playlist`, found once per load: the page reads it every body pass
    /// and a card playlist holds thousands of records.
    var index: Int? = nil
    var item: MonitorPlaybackItem? = nil
    var token: MonitorPlaybackItemToken
    var ready: Bool = false
    var nativeItemInstalled: Bool = false
    var loading: Bool = false
    var error: String? = nil
    var playRequested: Bool = true
    var reportedPlaying: Bool? = nil
    var reportedTransport: MonitorPlaybackTransportState? = nil
    var position: Double = 0
    var duration: Double? = nil
    var metadata: MonitorPlaybackMetadata = .init()
    var reachedEnd: Bool = false
    var muted: Bool = false
    var looping: Bool = false
    var conformTarget: Double? = nil
    var look: MonitorPlaybackLook<Look>? = nil
    var resolvedLookRequest: UUID?
    var scrubbing: Bool = false
    var scrubPosition: Double = 0
    var closed: Bool = false
  }
  @ObservationIgnored private var snapshot: Snapshot
  @ObservationIgnored private var publication: UInt64 = 0
  @ObservationIgnored private var notifying = false
  @ObservationIgnored private var pendingNotifications: [Field] = []
  private enum Field: Equatable {
    case active, playlist, item, token, ready, nativeItemInstalled, loading, error,
      playRequested, reportedPlaying, reportedTransport, position, duration, metadata, reachedEnd, muted,
      looping, conformTarget, look, scrubbing, scrubPosition, closed
  }

  public var active: MonitorMediaRecord<Payload>? {
    access(keyPath: \.active)
    return snapshot.active
  }
  public var playlist: [MonitorMediaRecord<Payload>] {
    access(keyPath: \.playlist)
    return snapshot.playlist
  }
  public var item: MonitorPlaybackItem? {
    access(keyPath: \.item)
    return snapshot.item
  }
  public var token: MonitorPlaybackItemToken {
    access(keyPath: \.token)
    return snapshot.token
  }
  public var ready: Bool {
    access(keyPath: \.ready)
    return snapshot.ready
  }
  public var nativeItemInstalled: Bool {
    access(keyPath: \.nativeItemInstalled)
    return snapshot.nativeItemInstalled
  }
  public var loading: Bool {
    access(keyPath: \.loading)
    return snapshot.loading
  }
  public var error: String? {
    access(keyPath: \.error)
    return snapshot.error
  }
  /// Operator transport intent, distinct from an unobserved native playhead.
  public var playRequested: Bool {
    access(keyPath: \.playRequested)
    return snapshot.playRequested
  }
  public var reportedPlaying: Bool? {
    access(keyPath: \.reportedPlaying)
    return snapshot.reportedPlaying
  }
  /// Native transport is unknown until the current item reports it.
  public var reportedTransport: MonitorPlaybackTransportState? {
    access(keyPath: \.reportedTransport)
    return snapshot.reportedTransport
  }
  /// Whether the primary transport action is Pause rather than Play.
  public var canPause: Bool {
    reportedTransport == .waiting ? playRequested : (reportedPlaying ?? playRequested)
  }
  public var position: Double {
    access(keyPath: \.position)
    return snapshot.position
  }
  public var duration: Double? {
    access(keyPath: \.duration)
    return snapshot.duration
  }
  public var metadata: MonitorPlaybackMetadata {
    access(keyPath: \.metadata)
    return snapshot.metadata
  }
  public var reachedEnd: Bool {
    access(keyPath: \.reachedEnd)
    return snapshot.reachedEnd
  }
  public var muted: Bool {
    access(keyPath: \.muted)
    return snapshot.muted
  }
  public var looping: Bool {
    access(keyPath: \.looping)
    return snapshot.looping
  }
  public var conformTarget: Double? {
    access(keyPath: \.conformTarget)
    return snapshot.conformTarget
  }
  public var look: MonitorPlaybackLook<Look>? {
    access(keyPath: \.look)
    return snapshot.look
  }
  public var scrubbing: Bool {
    access(keyPath: \.scrubbing)
    return snapshot.scrubbing
  }
  public var scrubPosition: Double {
    access(keyPath: \.scrubPosition)
    return snapshot.scrubPosition
  }
  public var closed: Bool {
    access(keyPath: \.closed)
    return snapshot.closed
  }
  public var transfer: MonitorTransfer? { look?.transfer }
  /// The already-captured lookup request whose facts were actually accepted.
  public var lookResolution: UUID? { look == nil ? nil : snapshot.resolvedLookRequest }

  @discardableResult private func publish(_ fields: [Field], _ change: (inout Snapshot) -> Void)
    -> Bool
  {
    change(&snapshot)
    publication &+= 1
    let committed = publication
    for field in fields where !pendingNotifications.contains(field) {
      pendingNotifications.append(field)
    }
    // A successor commits synchronously, while notification waits for the outgoing one-shot
    // observation callback to unregister. Reentering willSet would call that callback again.
    guard !notifying else { return publication == committed }
    notifying = true
    defer { notifying = false }
    while !pendingNotifications.isEmpty {
      let field = pendingNotifications.removeFirst()
      switch field {
      case .active: withMutation(keyPath: \.active) {}
      case .playlist: withMutation(keyPath: \.playlist) {}
      case .item: withMutation(keyPath: \.item) {}
      case .token: withMutation(keyPath: \.token) {}
      case .ready: withMutation(keyPath: \.ready) {}
      case .nativeItemInstalled: withMutation(keyPath: \.nativeItemInstalled) {}
      case .loading: withMutation(keyPath: \.loading) {}
      case .error: withMutation(keyPath: \.error) {}
      case .playRequested: withMutation(keyPath: \.playRequested) {}
      case .reportedPlaying: withMutation(keyPath: \.reportedPlaying) {}
      case .reportedTransport: withMutation(keyPath: \.reportedTransport) {}
      case .position: withMutation(keyPath: \.position) {}
      case .duration: withMutation(keyPath: \.duration) {}
      case .metadata: withMutation(keyPath: \.metadata) {}
      case .reachedEnd: withMutation(keyPath: \.reachedEnd) {}
      case .muted: withMutation(keyPath: \.muted) {}
      case .looping: withMutation(keyPath: \.looping) {}
      case .conformTarget: withMutation(keyPath: \.conformTarget) {}
      case .look: withMutation(keyPath: \.look) {}
      case .scrubbing: withMutation(keyPath: \.scrubbing) {}
      case .scrubPosition: withMutation(keyPath: \.scrubPosition) {}
      case .closed: withMutation(keyPath: \.closed) {}
      }
    }
    return publication == committed
  }

  @ObservationIgnored public let native: any MonitorPlaybackPort
  @ObservationIgnored private let libraryLifetime: UUID
  @ObservationIgnored private let library: MonitorMediaLibraryModel<Payload>
  @ObservationIgnored private let candidates:
    @MainActor @Sendable (MonitorMediaRecord<Payload>) -> [MonitorPlaybackCandidate]
  @ObservationIgnored private let resolveLook:
    @MainActor @Sendable (MonitorMediaRecord<Payload>, MonitorPlaybackItem) async ->
      MonitorPlaybackLook<Look>?
  @ObservationIgnored private let now: @MainActor @Sendable () -> MonotonicInstant
  @ObservationIgnored private let readyTimeout: Duration?
  @ObservationIgnored private let retryNativeFailures: Bool
  @ObservationIgnored private let lookTiming: MonitorPlaybackLookTiming
  @ObservationIgnored private let startTiming: MonitorPlaybackStartTiming
  @ObservationIgnored private let seekEndClearance: Double
  @ObservationIgnored private let sceneLossPolicy: MonitorPlaybackSceneLossPolicy
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var lookTask: Task<Void, Never>?
  @ObservationIgnored private var lookRevision = UUID()
  @ObservationIgnored private var seekTask: Task<Void, Never>?
  @ObservationIgnored private var playRequestRevision: UInt64 = 0
  @ObservationIgnored private var writer: MonitorMediaCacheWrite?
  @ObservationIgnored private var scrub: Scrub?
  @ObservationIgnored private var sceneActive = true
  @ObservationIgnored private var presentationActive = true
  @ObservationIgnored private var captureAdmission:
    (@MainActor @Sendable (MonitorMediaRecord<Payload>) -> MonitorPlaybackAdmission)?
  @ObservationIgnored private var itemAdmission: MonitorPlaybackAdmission?
  @ObservationIgnored private var admissionWatch = UUID()
  private struct Scrub {
    let token: MonitorPlaybackScrubToken
    let resume: Bool
    let origin: Double
    var lastSeek: MonotonicInstant?
  }

  public init(
    library: MonitorMediaLibraryModel<Payload>, native: any MonitorPlaybackPort,
    readyTimeout: Duration? = .seconds(8), retryNativeFailures: Bool = true,
    lookTiming: MonitorPlaybackLookTiming = .afterNativeReadiness,
    startTiming: MonitorPlaybackStartTiming = .afterNativeReadiness,
    candidates:
      @escaping @MainActor @Sendable (MonitorMediaRecord<Payload>) ->
      [MonitorPlaybackCandidate],
    // Optional rather than a closure-literal default, which each client would compile again
    // with a different async context size (swiftlang/swift#92017; see `hostSleep(for:)`).
    resolveLook:
      (@MainActor @Sendable (MonitorMediaRecord<Payload>, MonitorPlaybackItem) async
      -> MonitorPlaybackLook<Look>?)? = nil,
    now: @escaping @MainActor @Sendable () -> MonotonicInstant = { .now() },
    seekEndClearance: Double = 0.05,
    sceneLossPolicy: MonitorPlaybackSceneLossPolicy = .clearRequest
  ) {
    self.library = library
    libraryLifetime = library.lifetimeToken
    self.native = native
    self.candidates = candidates
    self.resolveLook = resolveLook ?? { _, _ in nil }
    self.now = now
    self.readyTimeout = readyTimeout
    self.retryNativeFailures = retryNativeFailures
    self.lookTiming = lookTiming
    self.startTiming = startTiming
    self.seekEndClearance = seekEndClearance.isFinite && seekEndClearance >= 0 ? seekEndClearance : 0.05
    self.sceneLossPolicy = sceneLossPolicy
    snapshot = .init(token: .init(owner: UUID(), revision: 0))
    native.retireItem(for: token)
    watchLibrary()
    native.onEvent = { [weak self] token, event in self?.receive(event, token: token) }
  }

  /// Configure once before the first item. Every load captures fresh immutable host facts.
  /// Existing construction has no additional admission policy.
  public func setItemAdmission(
    _ capture:
      @escaping @MainActor @Sendable (MonitorMediaRecord<Payload>) -> MonitorPlaybackAdmission
  ) {
    guard active == nil, !closed else { return }
    captureAdmission = capture
  }

  public var canGoPrevious: Bool { index.map { $0 > 0 } ?? false }
  public var canGoNext: Bool { index.map { $0 + 1 < playlist.count } ?? false }
  public var isActive: Bool { current(token) }
  /// This owner still holds its item on a browsing library, without asking the host's item
  /// admission. Presentation that repeats per frame or per body pass (buffered extent, the
  /// glass backdrop) reads this; actions and lifecycle keep the admitted ``isActive``.
  public var holdsItem: Bool { ownsItem(token) }
  private var index: Int? {
    access(keyPath: \.active)
    access(keyPath: \.playlist)
    return snapshot.index
  }
  public var rate: Double {
    guard let target = conformTarget, let capture = metadata.conform.captureRate else {
      return 1
    }
    return MonitorConformPreview.speed(captureRate: capture, targetRate: target)
  }
  private func ownsItem(_ admitted: MonitorPlaybackItemToken) -> Bool {
    !closed && token == admitted && library.lifetimeToken == libraryLifetime && library.browsing
  }
  private func capturedItemAdmission(_ admitted: MonitorPlaybackItemToken) -> Bool? {
    guard ownsItem(admitted) else { return nil }
    let admission = itemAdmission
    let accepted = admission?.isCurrent() ?? true
    // A host predicate can synchronously retire this item or load its successor.
    guard ownsItem(admitted) else { return nil }
    return accepted
  }
  private func current(_ admitted: MonitorPlaybackItemToken) -> Bool {
    capturedItemAdmission(admitted) == true
  }
  private func admit(_ admitted: MonitorPlaybackItemToken) -> Bool {
    guard let accepted = capturedItemAdmission(admitted) else { return false }
    if !accepted { close() }
    return accepted
  }
  private func watchAdmission() {
    guard let admission = itemAdmission, !closed else { return }
    let request = UUID()
    admissionWatch = request
    let admitted = token
    withObservationTracking {
      _ = admission.isCurrent()
    } onChange: { [weak self] in
      // Library snapshots commit before notification; reject their retired authority now.
      // Ordinary observed setters notify before assigning. If still admitted, validate again
      // after that mutation, then rearm. Native publication independently checks authority.
      MainActor.assumeIsolated {
        guard let self, self.admissionWatch == request, self.token == admitted, !self.closed,
          self.admit(admitted)
        else { return }
        Task { @MainActor [weak self] in
          guard let self, self.admissionWatch == request, self.token == admitted,
            !self.closed, self.admit(admitted)
          else { return }
          self.watchAdmission()
        }
      }
    }
  }
  private func watchLibrary() {
    withObservationTracking {
      _ = library.lifetimeToken
    } onChange: { [weak self] in
      Task { @MainActor in self?.close() }
    }
  }

  public func load(
    _ record: MonitorMediaRecord<Payload>, playlist: [MonitorMediaRecord<Payload>],
    play: Bool = true
  ) {
    let previous = token
    guard admit(previous) else { return }
    retirePending()
    guard admit(previous) else { return }
    let admission = captureAdmission?(record)
    guard admit(previous) else { return }
    itemAdmission = admission
    guard admission?.isCurrent() ?? true else {
      close()
      return
    }
    let admitted = MonitorPlaybackItemToken(
      owner: previous.owner, revision: previous.revision &+ 1)
    guard
      publish(
        [
          .token, .active, .playlist, .item, .ready, .nativeItemInstalled, .loading,
          .error, .reachedEnd, .position, .duration, .metadata, .conformTarget, .look,
          .reportedPlaying, .reportedTransport, .playRequested, .scrubbing,
        ],
        { state in
          state.token = admitted
          state.active = record
          state.playlist = playlist
          state.index = playlist.firstIndex { $0.asset.id == record.asset.id }
          state.item = nil
          state.ready = false
          state.nativeItemInstalled = false
          state.loading = true
          state.error = nil
          state.reachedEnd = false
          state.position = 0
          state.duration = record.asset.durationSeconds
          state.metadata = .init(
            duration: state.duration,
            width: record.asset.pixelSize.map { Double($0.width) },
            height: record.asset.pixelSize.map { Double($0.height) },
            conform: .init(captureRate: record.asset.frameRate))
          state.conformTarget = nil
          state.look = nil
          state.reportedPlaying = nil
          state.reportedTransport = nil
          state.playRequested = play
          state.scrubbing = false
        }), admit(admitted)
    else { return }
    native.retireItem(for: admitted)
    guard admit(admitted) else { return }
    watchAdmission()
    let sourceChoices = candidates(record)
    let hasHostSource = sourceChoices.contains { candidate in
      if case .hostDownload = candidate { return true }
      return false
    }
    guard admit(admitted) else { return }
    let binding = library.binding
    let rootGeneration = library.cache.directory.generation
    loadTask = Task { [weak self] in
      guard let self, self.admit(admitted), !Task.isCancelled else { return }
      for candidate in sourceChoices {
        guard self.admit(admitted), !Task.isCancelled else { return }
        let prepared: MonitorPlaybackItem
        do {
          prepared = try await self.prepare(
            candidate, record: record, token: admitted,
            binding: binding, rootGeneration: rootGeneration)
        } catch {
          guard self.admit(admitted), !Task.isCancelled else { return }
          continue
        }
        guard self.admit(admitted), !Task.isCancelled else { return }
        do {
          guard
            self.publish(
              [.item, .nativeItemInstalled],
              {
                $0.item = prepared
                $0.nativeItemInstalled = false
              }), self.admit(admitted), !Task.isCancelled
          else { return }
          if self.lookTiming == .beforeNativePreparation {
            let request = self.lookRevision
            let value = await self.resolveLook(record, prepared)
            guard self.admit(admitted), self.lookRevision == request, !Task.isCancelled
            else { return }
            guard self.publish([.look], { $0.look = value; $0.resolvedLookRequest = value == nil ? nil : request }), self.admit(admitted),
              !Task.isCancelled
            else { return }
          }
          var facts = try await self.native.prepare(
            prepared, token: admitted, readyTimeout: self.readyTimeout)
          guard self.admit(admitted), !Task.isCancelled else { return }
          if facts.conform.captureRate == nil {
            facts.conform.captureRate = record.asset.frameRate
          }
          let startAfterReady =
            self.startTiming == .afterNativeReadiness || !self.nativeItemInstalled
          // Clear only this task's handle before callbacks can create another load.
          self.loadTask = nil
          guard
            self.publish(
              [
                .item, .metadata, .duration, .nativeItemInstalled, .ready, .loading,
                .error,
              ],
              {
                $0.item = prepared
                $0.metadata = facts
                $0.duration = facts.duration ?? record.asset.durationSeconds
                $0.nativeItemInstalled = true
                $0.ready = true
                $0.loading = false
                $0.error = nil
              }), self.admit(admitted), !Task.isCancelled
          else { return }
          guard self.applyOutput(admitted) else { return }
          if startAfterReady, self.playRequested, self.presentationActive,
            self.sceneActive
          {
            self.native.play(rate: self.rate, token: admitted)
          }
          guard self.admit(admitted) else { return }
          if self.lookTiming == .afterNativeReadiness { self.refreshTransfer() }
          return
        } catch {
          guard self.admit(admitted), !Task.isCancelled else { return }
          if !self.retryNativeFailures { break }
        }
      }
      guard self.admit(admitted), !Task.isCancelled else { return }
      self.loadTask = nil
      self.publish([.loading, .error]) {
        $0.loading = false
        if $0.error == nil {
          $0.error =
            (self.library.canTransfer || hasHostSource)
            ? "Could not open that clip." : "This clip is not cached on the phone."
        }
      }
    }
  }

  private func prepare(
    _ candidate: MonitorPlaybackCandidate, record: MonitorMediaRecord<Payload>,
    token: MonitorPlaybackItemToken, binding: MediaBrowseBinding?, rootGeneration: UInt64
  ) async throws -> MonitorPlaybackItem {
    switch candidate {
    case .cached(let item): return item
    case .representation(let representation, let mime, let source):
      guard
        let choice = record.asset.representations.first(where: { $0.id == representation })
      else {
        throw MonitorPlaybackError.unavailable
      }
      let url = try await library.cacheRepresentation(representation, asset: record.asset.id)
      guard admit(token), !Task.isCancelled else { throw MonitorPlaybackError.retired }
      return .init(url: url, mimeType: mime, sourceKey: source, role: choice.role)
    case .hostDownload(
      let address, let mime, let source, let role, let admission, let didCommit, let transfer):
      let directory = library.cache.directory
      guard admit(token), admission.isCurrent(), directory.generation == rootGeneration else {
        throw MonitorPlaybackError.retired
      }
      if let existing = directory.existing(address) {
        return .init(url: existing, mimeType: mime, sourceKey: source, role: role)
      }
      let write = try directory.beginWrite(at: address)
      writer = write
      defer {
        write.abort()
        if writer === write { writer = nil }
      }
      let sink = PlaybackSink(write: write) { [weak self] in
        self?.admit(token) == true && admission.isCurrent()
          && directory.generation == rootGeneration
      }
      let receipt = try await transfer(sink)
      guard admit(token), admission.isCurrent(), directory.generation == rootGeneration,
        !Task.isCancelled
      else { throw MonitorPlaybackError.retired }
      let url = try write.commit(receipt)
      library.refreshLocalCache()
      guard admit(token), admission.isCurrent(), directory.generation == rootGeneration else {
        throw MonitorPlaybackError.retired
      }
      didCommit()
      guard admit(token), admission.isCurrent(), directory.generation == rootGeneration else {
        throw MonitorPlaybackError.retired
      }
      return .init(url: url, mimeType: mime, sourceKey: source, role: role)
    case .download(let address, let mime, let source, let role, let transfer):
      let directory = library.cache.directory
      guard let binding, library.binding == binding, library.browsing,
        library.record(record.asset.id) != nil,
        directory.generation == rootGeneration
      else { throw MonitorPlaybackError.retired }
      if let existing = directory.existing(address) {
        return .init(url: existing, mimeType: mime, sourceKey: source, role: role)
      }
      let write = try directory.beginWrite(at: address)
      writer = write
      defer {
        write.abort()
        if writer === write { writer = nil }
      }
      let sink = PlaybackSink(write: write) { [weak self] in
        self?.admit(token) == true && self?.library.binding == binding
          && self?.library.record(record.asset.id) != nil
          && self?.library.browsing == true && directory.generation == rootGeneration
      }
      let receipt = try await transfer(sink)
      guard admit(token), library.binding == binding, library.browsing,
        library.record(record.asset.id) != nil,
        directory.generation == rootGeneration, !Task.isCancelled
      else { throw MonitorPlaybackError.retired }
      let url = try write.commit(receipt)
      library.refreshLocalCache()
      return .init(url: url, mimeType: mime, sourceKey: source, role: role)
    }
  }

  public func refreshTransfer() {
    let admitted = token
    guard admit(admitted), ready, let active, let item else { return }
    lookTask?.cancel()
    lookRevision = UUID()
    let request = lookRevision
    lookTask = Task { [weak self] in
      guard let self, self.admit(admitted), !Task.isCancelled else { return }
      let value = await self.resolveLook(active, item)
      guard self.admit(admitted), self.lookRevision == request, !Task.isCancelled else {
        return
      }
      self.lookTask = nil
      self.publish([.look]) { $0.look = value; $0.resolvedLookRequest = value == nil ? nil : request }
    }
  }

  private func receive(_ event: MonitorPlaybackEvent, token admitted: MonitorPlaybackItemToken) {
    guard admit(admitted) else { return }
    switch event {
    case .itemInstalled:
      guard !nativeItemInstalled,
        publish([.nativeItemInstalled], { $0.nativeItemInstalled = true }), admit(admitted),
        applyOutput(admitted)
      else { return }
      if startTiming == .afterNativeItemInstallation, playRequested, presentationActive,
        sceneActive
      {
        native.play(rate: rate, token: admitted)
      }
    case .position(let seconds):
      if !scrubbing, let seconds, seconds.isFinite, seconds >= 0 {
        publish([.position]) { $0.position = seconds }
      }
    case .playing(let value):
      publish([.reportedPlaying, .reportedTransport]) {
        $0.reportedPlaying = value
        $0.reportedTransport = nil
      }
    case .transport(let value):
      publish([.reportedPlaying, .reportedTransport]) {
        $0.reportedTransport = value
        $0.reportedPlaying = value.map { $0 == .playing }
      }
    case .metadata(var facts):
      if facts.conform.captureRate == nil {
        facts.conform.captureRate = active?.asset.frameRate
      }
      let invalidTarget =
        conformTarget.map {
          !MonitorConformPreview.availability(for: facts.conform).targets.contains($0)
        } ?? false
      guard
        publish(
          [.metadata, .duration, .conformTarget],
          {
            $0.metadata = facts
            $0.duration = facts.duration ?? $0.duration
            if invalidTarget { $0.conformTarget = nil }
          }), admit(admitted)
      else { return }
      if invalidTarget { _ = applyOutput(admitted) }
    case .ended:
      if looping {
        seek(to: 0, resume: playRequested, admitted: admitted)
      } else {
        publish([.reachedEnd, .playRequested, .position]) {
          $0.reachedEnd = true
          $0.playRequested = false
          $0.position = $0.duration ?? $0.position
        }
      }
    case .failed(let message):
      publish([.error, .loading, .ready]) {
        $0.error = message
        $0.loading = false
        $0.ready = false
      }
    }
  }

  public func setPlaying(_ play: Bool) {
    let admitted = token
    playRequestRevision &+= 1
    setPlaying(play, admitted: admitted, request: playRequestRevision)
  }
  private func setPlaying(
    _ play: Bool, admitted: MonitorPlaybackItemToken, request: UInt64
  ) {
    guard admit(admitted), request == playRequestRevision,
      publish([.playRequested], { $0.playRequested = play }),
      admit(admitted), request == playRequestRevision
    else { return }
    if ready, presentationActive, sceneActive {
      if play {
        native.play(rate: rate, token: admitted)
      } else {
        native.pause(token: admitted)
      }
    }
  }
  public func togglePlaying() {
    if reachedEnd { restart() } else { setPlaying(!canPause) }
  }
  public func setMuted(_ value: Bool) {
    let admitted = token
    guard admit(admitted), publish([.muted], { $0.muted = value }), admit(admitted) else {
      return
    }
    _ = applyOutput(admitted)
  }
  public func setLooping(_ value: Bool) {
    guard admit(token) else { return }
    publish([.looping]) { $0.looping = value }
  }
  public func setConformTarget(_ value: Double?) {
    let admitted = token
    guard admit(admitted),
      value == nil
        || value.map(
          MonitorConformPreview.availability(for: metadata.conform).targets.contains)
          == true,
      publish([.conformTarget], { $0.conformTarget = value }), admit(admitted),
      applyOutput(admitted)
    else { return }
    if playRequested, ready, presentationActive, sceneActive {
      native.play(rate: rate, token: admitted)
    }
  }
  private func applyOutput(_ admitted: MonitorPlaybackItemToken) -> Bool {
    guard admit(admitted) else { return false }
    native.setMuted(muted || conformTarget != nil, token: admitted)
    return admit(admitted)
  }
  public func restart() { seek(to: 0, resume: true, admitted: token) }
  public func seek(by seconds: Double) {
    seek(to: position + seconds, resume: false, admitted: token)
  }
  private func bounded(_ seconds: Double) -> Double? {
    guard seconds.isFinite, let duration, duration.isFinite, duration > 0 else { return nil }
    return min(duration, max(0, seconds))
  }
  private func seek(to seconds: Double, resume: Bool, admitted: MonitorPlaybackItemToken) {
    let request = playRequestRevision
    guard ready, let target = bounded(seconds), admit(admitted) else { return }
    seekTask?.cancel()
    seekTask = nil
    guard
      publish(
        [.position, .scrubPosition, .reachedEnd],
        {
          $0.position = target
          $0.scrubPosition = target
          if $0.reachedEnd, target + seekEndClearance < ($0.duration ?? 0) { $0.reachedEnd = false }
        }), admit(admitted)
    else { return }
    seekTask = Task { [weak self] in
      guard let self, self.admit(admitted), !Task.isCancelled else { return }
      let completed = await self.native.seek(seconds: target, tolerance: 0, token: admitted)
      guard self.admit(admitted), !Task.isCancelled else { return }
      self.seekTask = nil
      guard completed, self.presentationActive, self.sceneActive else { return }
      if resume { self.setPlaying(true, admitted: admitted, request: request) }
    }
  }

  @discardableResult public func beginScrub() -> MonitorPlaybackScrubToken? {
    let item = token
    guard ready, admit(item), sceneActive, presentationActive else { return nil }
    let admitted = scrub?.token ?? MonitorPlaybackScrubToken(item: item)
    if scrub == nil {
      seekTask?.cancel()
      seekTask = nil
      scrub = .init(
        token: admitted, resume: canPause, origin: position)
      guard publish([.scrubPosition], { $0.scrubPosition = $0.position }),
        admit(item), scrub?.token == admitted
      else { return nil }
      native.pause(token: item)
    }
    guard admit(item), scrub?.token == admitted,
      publish([.scrubbing], { $0.scrubbing = true })
    else { return nil }
    return admit(item) && scrub?.token == admitted ? admitted : nil
  }
  public func updateScrub(seconds: Double, admitted: MonitorPlaybackScrubToken) {
    guard var edit = scrub, edit.token == admitted, admit(admitted.item),
      let target = bounded(seconds),
      presentationActive, sceneActive
    else { return }
    guard
      publish(
        [.scrubPosition, .reachedEnd],
        {
          $0.scrubPosition = target
          if $0.reachedEnd, target + seekEndClearance < ($0.duration ?? 0) { $0.reachedEnd = false }
        }), admit(admitted.item), scrub?.token == admitted
    else { return }
    let instant = now()
    if edit.lastSeek == nil || instant - edit.lastSeek! >= .milliseconds(75) {
      edit.lastSeek = instant
      scrub = edit
      seekTask?.cancel()
      seekTask = Task { [weak self] in
        guard let self, self.admit(admitted.item), self.scrub?.token == admitted,
          !Task.isCancelled
        else { return }
        _ = await self.native.seek(seconds: target, tolerance: 0.1, token: admitted.item)
      }
    }
  }
  public func updateFrameScrub(delta: Double, width: Double, admitted: MonitorPlaybackScrubToken) {
    guard let edit = scrub, edit.token == admitted, width.isFinite, width > 0, let duration
    else { return }
    updateScrub(seconds: edit.origin + delta / width * duration, admitted: admitted)
  }
  public func commitScrub(admitted: MonitorPlaybackScrubToken) {
    guard let edit = scrub, edit.token == admitted, admit(admitted.item), presentationActive,
      sceneActive
    else { return }
    let target = scrubPosition
    scrub = nil
    guard publish([.scrubbing], { $0.scrubbing = false }), admit(admitted.item) else { return }
    seek(to: target, resume: edit.resume, admitted: admitted.item)
  }
  public func cancelScrub(interrupted: Bool, admitted: MonitorPlaybackScrubToken? = nil) {
    if let admitted, scrub?.token != admitted || !admit(admitted.item) { return }
    cancelScrub(interrupted: interrupted, admitted: token)
  }
  private func cancelScrub(interrupted: Bool, admitted: MonitorPlaybackItemToken) {
    let request = playRequestRevision
    guard admit(admitted) else { return }
    let edit = scrub
    scrub = nil
    seekTask?.cancel()
    seekTask = nil
    guard publish([.scrubbing], { $0.scrubbing = false }), admit(admitted),
      interrupted, let edit, edit.token.item == admitted, presentationActive, sceneActive
    else { return }
    seekTask = Task { [weak self] in
      await Task.yield()
      guard let self, self.admit(admitted), !Task.isCancelled, !self.scrubbing,
        self.presentationActive, self.sceneActive
      else { return }
      self.seekTask = nil
      if edit.resume { self.setPlaying(true, admitted: admitted, request: request) }
    }
  }
  public func setPresentationActive(_ value: Bool) {
    let admitted = token
    guard admit(admitted) else { return }
    presentationActive = value
    if !value {
      cancelScrub(interrupted: false, admitted: admitted)
      if admit(admitted) { native.pause(token: admitted) }
    } else if sceneActive, playRequested, ready {
      native.play(rate: rate, token: admitted)
    }
  }
  public func setSceneActive(_ value: Bool) {
    let admitted = token
    guard admit(admitted) else { return }
    sceneActive = value
    if !value {
      if sceneLossPolicy == .clearRequest {
        playRequestRevision &+= 1
        // The cleared request reads paused before native reports it, so the first toggle on return resumes.
        publish([.playRequested, .reportedPlaying, .reportedTransport]) {
          $0.playRequested = false
          $0.reportedPlaying = false
          $0.reportedTransport = nil
        }
        // A same-item observer may publish during that commit; only a successor or a regained scene skips the pause.
        guard admit(admitted), !sceneActive else { return }
      }
      cancelScrub(interrupted: false, admitted: admitted)
      if admit(admitted) { native.pause(token: admitted) }
    } else if presentationActive, playRequested, ready {
      native.play(rate: rate, token: admitted)
    }
  }
  public func goToAdjacent(_ offset: Int) {
    guard let index, playlist.indices.contains(index + offset) else { return }
    load(playlist[index + offset], playlist: playlist)
  }
  private func retirePending() {
    loadTask?.cancel()
    loadTask = nil
    lookTask?.cancel()
    lookTask = nil
    lookRevision = UUID()
    seekTask?.cancel()
    seekTask = nil
    writer?.abort()
    writer = nil
    scrub = nil
  }
  public func close() {
    guard !closed else { return }
    let retired = MonitorPlaybackItemToken(owner: token.owner, revision: token.revision &+ 1)
    publish([.closed, .token, .ready, .nativeItemInstalled, .loading, .scrubbing]) {
      $0.closed = true
      $0.token = retired
      $0.ready = false
      $0.nativeItemInstalled = false
      $0.loading = false
      $0.scrubbing = false
    }
    admissionWatch = UUID()
    itemAdmission = nil
    retirePending()
    native.close(token: retired)
  }

}

@MainActor private final class PlaybackSink: MediaByteSink {
  let write: MonitorMediaCacheWrite
  let admitted: @MainActor @Sendable () -> Bool
  init(write: MonitorMediaCacheWrite, admitted: @escaping @MainActor @Sendable () -> Bool) {
    self.write = write
    self.admitted = admitted
  }
  func write(_ chunk: Data) async throws {
    guard admitted(), !Task.isCancelled else { throw MonitorPlaybackError.retired }
    try await write.write(chunk)
  }
}
