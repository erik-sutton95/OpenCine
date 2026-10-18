#if canImport(UIKit) && canImport(AVFoundation) && canImport(CoreImage)
  import AVFoundation
  import CoreImage
  import CoreVideo
  import OpenCineMedia
  import QuartzCore
  import UIKit

  /// Present order for clip assists; same contract as live `HevcDecoder.applyAssistResult`.
  /// Identity stays on `AVPlayerLayer` until Metal owns LUT replace; then the player
  /// hides (live hides the VT layer the same way). Overlay (PEAK / FALSE / ZEBRA)
  /// keeps the player. `MonitorPictureHost` unhides only after a bake presents.
  public enum MonitorPlaybackFeedHandoff {
    public struct Plan: Equatable {
      public var showPlayer: Bool
      public var showFeed: Bool
      public var overlay: Bool
      public var unmanaged: Bool
    }

    public static func plan(
      effects: MonitorFrameEffects,
      overlayOnly: Bool,
      unmanagedBake: Bool,
      metalHasPresented: Bool,
      hdrDisplay: Bool = false
    ) -> Plan {
      if hdrDisplay && !effects.needsGPUFeed {
        return Plan(
          showPlayer: !metalHasPresented, showFeed: metalHasPresented,
          overlay: false, unmanaged: false)
      }
      if !effects.needsGPUFeed {
        return Plan(showPlayer: true, showFeed: false, overlay: false, unmanaged: false)
      }
      if overlayOnly || effects.needsOverlayFeed {
        return Plan(
          showPlayer: true, showFeed: metalHasPresented, overlay: true, unmanaged: true)
      }
      // Same as live `HevcDecoder.adoptReplacingMetalFeed`: identity until
      // Metal owns the cube, then hide the HEVC layer so AVPlayer is not a
      // second present under the grade.
      return Plan(
        showPlayer: !metalHasPresented,
        showFeed: metalHasPresented,
        overlay: false,
        unmanaged: presentUnmanaged(overlay: false, unmanagedBake: unmanagedBake))
    }

    /// Overlay chrome is always unmanaged. LUT replace follows the engine -
    /// same `unmanaged: result.unmanagedBake` as live `HevcDecoder`.
    public static func presentUnmanaged(overlay: Bool, unmanagedBake: Bool) -> Bool {
      overlay || unmanagedBake
    }

    /// Next/prev keeps the LUT chip and often the last buffer / metal flag.
    /// Until *this item* has presented, keep force-pulling; a single pull
    /// before the decoder has a frame is a no-op, and display-link
    /// `force: false` will not resubmit `lastBuffer`.
    public static func shouldForcePull(
      effectsChanged: Bool,
      hasLastBuffer: Bool,
      metalHasPresented: Bool,
      itemHasPresented: Bool
    ) -> Bool {
      if !itemHasPresented { return true }
      return effectsChanged || !hasLastBuffer || !metalHasPresented
    }

    /// Scopes, Face AF and inspector samples leave the picture on `AVPlayerLayer`,
    /// so the item is ready once its first source frame is processed. Waiting for
    /// a Metal completion that never comes resubmitted `lastBuffer` every display
    /// tick, including while paused.
    public static func sourceReadyWithoutMetal(needsGPUFeed: Bool, hdrDisplay: Bool) -> Bool {
      !needsGPUFeed && !hdrDisplay
    }

    /// One `MonitorPlaybackFeedSession` is shared across SwiftUI identities. A slide
    /// `.id(active.id)` used to spawn a second representable whose
    /// `updateUIView` stole `attach` on the way out; LUT chrome stayed armed
    /// while the surviving host never presented.
    public static func shouldAdoptHost(
      incomingGeneration: Int, currentGeneration: Int?, isSameHost: Bool
    ) -> Bool {
      if isSameHost { return true }
      guard let currentGeneration else { return true }
      return incomingGeneration > currentGeneration
    }

    /// Overlay bakes set `hasPresentedFrame`, but LUT then flips the Metal layer
    /// opaque. Treating that stale flag as ownership is a black plate over the player.
    public static func replaceOwnsPicture(hasPresentedFrame: Bool, lastPresentWasOverlay: Bool)
      -> Bool
    {
      FeedPresentPolicy.replaceOwnsPicture(
        hasPresentedFrame: hasPresentedFrame,
        lastPresentWasOverlay: lastPresentWasOverlay)
    }
  }

  /// Pull clock for preview LUT. LUT-off is `AVPlayerLayer` at the clip rate.
  /// A 15–30 Hz display link preferred 24 is the 22–23 fps hitch: 30p proxies
  /// get pulldown, and the system may shed to 15. Poll the display; the cube
  /// only bakes when `hasNewPixelBuffer` (or until the first present).
  public enum MonitorPlaybackDisplayLink {
    public static let pollRange = CAFrameRateRange(minimum: 24, maximum: 120, preferred: 120)

    public static func shouldPull(itemHasPresented: Bool, hasNewPixelBuffer: Bool) -> Bool {
      if !itemHasPresented { return true }
      return hasNewPixelBuffer
    }

    /// A paused, presented item has nothing to poll. Park the link (a 120 Hz
    /// link also holds ProMotion at 120 Hz) and let the output's media-data
    /// notification wake it on play or seek, as Apple's video-output sample does.
    public static func shouldPark(itemHasPresented: Bool, playerRate: Float) -> Bool {
      itemHasPresented && playerRate == 0
    }

    /// Paused ticks with no new picture before parking. An exact seek while
    /// paused decodes from the previous keyframe (tens of ms), and the scope
    /// throttle (up to 500 ms when critical) can drop the first new sample, so
    /// the link keeps polling this long and forces one last pull before parking.
    public static let parkAfter: CFTimeInterval = 0.6

    public static func parkIsDue(idleSince: CFTimeInterval?, now: CFTimeInterval) -> Bool {
      guard let idleSince else { return false }
      return now - idleSince >= parkAfter
    }
  }

  /// Pixel buffers pulled from the player for the live compositor.
  ///
  /// Preview LUT is `CIColorCube` on this buffer, not `AVVideoComposition`.
  /// 32BGRA forces an HEVC→RGB conversion every frame; live grades 420 IOSurface.
  public enum MonitorPlaybackVideoOutput {
    public static var pixelBufferAttributes: [String: any Sendable] {
      [
        kCVPixelBufferPixelFormatTypeKey as String:
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Int],
      ]
    }

    public static var pixelFormat: OSType? {
      let value = pixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey as String]
      if let number = value as? NSNumber { return number.uint32Value }
      return value as? OSType
    }

    /// True when the output asks AVPlayer to author RGB instead of native YUV.
    public static var forcesRGBConversion: Bool {
      pixelFormat == kCVPixelFormatType_32BGRA
    }
  }

  /// Player → pixel buffer → `MonitorAssistEngine` → `MonitorPictureHost`.
  ///
  /// `AVVideoComposition` after `replaceCurrentItem` never called the compositor on
  /// the parked frame, so LUT / PEAK / FALSE / ZEBRA looked like a no-op. Video
  /// output is attached **before** the item becomes current; a late add drops
  /// buffers until the next seek.
  open class MonitorPlaybackFeedSession: NSObject, @unchecked Sendable {
    public let output: AVPlayerItemVideoOutput
    private let assistEngine: MonitorAssistEngine
    private let hdrDisplay: @Sendable () -> Bool
    private let journal: @Sendable (String) -> Void
    private let sourceAdvanced: @Sendable () -> Void
    /// The clip a source states outright for a transfer (for example from its recording codec
    /// and ISO). Declared on every playback publication this feed opens; nil keeps the measured
    /// ceiling.
    @MainActor private let declaredClip: (@MainActor (MonitorTransfer) -> Int?)?
    /// Main-owned publication authority. A rejected host closes its logical/native owner,
    /// advancing the existing pull fence. Background queues never read gallery state.
    @MainActor public var sourceAdmission: (@MainActor @Sendable () -> Bool)?
    @MainActor private func admitsSource() -> Bool { sourceAdmission?() ?? true }
    @MainActor private var closed = false
    @MainActor private var pictureOwnership: MonitorPictureHost.Ownership?
    private let workingRaster = MonitorWorkingRaster()
    @MainActor private let linkTarget = DisplayLinkTarget()
    private let pullQueue = DispatchQueue(
      label: "opencine.playback-pull", qos: .userInteractive)
    @MainActor private var displayLink: CADisplayLink?
    @MainActor private weak var boundItem: AVPlayerItem?
    @MainActor private weak var player: AVPlayer?
    @MainActor private weak var host: MonitorPlaybackFeedHost?
    @MainActor private var sampleSource: LiveFrameSampleBus.Source?
    @MainActor private weak var sampleBus: LiveFrameSampleBus?
    @MainActor private var effects = MonitorFrameEffects()
    @MainActor private var transfer = MonitorTransfer.rec709
    /// pullQueue-owned. Main must not read or write it, and must not wait on pullQueue.
    private var lastBuffer: CVPixelBuffer?
    @MainActor private var lastBackdropBuffer: CVPixelBuffer?
    @MainActor private var lastOverlayOnly = false
    @MainActor private var lastUnmanagedBake = false
    private var pendingKick = false
    private var loggedRaster = false
    @MainActor private var lastPresentHealthLogAt: Date?
    @MainActor private var hostGeneration = 0
    /// Bumped in `prepare`. `presentedEpoch` catches up in `adoptPresentedFeed`.
    private let sourceFence = PlaybackPullFence()
    private var itemEpoch: UInt64 { sourceFence.epoch }
    @MainActor private var presentedEpoch: UInt64 = 0
    /// First paused tick without a new picture; see `MonitorPlaybackDisplayLink.parkAfter`.
    @MainActor private var idleSince: CFTimeInterval?

    @MainActor public init(
      configuration: MonitorAssistConfiguration,
      hdrDisplay: @escaping @Sendable () -> Bool,
      journal: @escaping @Sendable (String) -> Void = { _ in },
      sourceAdvanced: @escaping @Sendable () -> Void = {},
      declaredClip: (@MainActor (MonitorTransfer) -> Int?)? = nil
    ) {
      assistEngine = MonitorAssistEngine(configuration: configuration)
      self.declaredClip = declaredClip
      self.hdrDisplay = hdrDisplay
      self.journal = journal
      self.sourceAdvanced = sourceAdvanced
      output = AVPlayerItemVideoOutput(
        pixelBufferAttributes: MonitorPlaybackVideoOutput.pixelBufferAttributes)
      super.init()
      output.setDelegate(self, queue: pullQueue)
      linkTarget.handler = { [weak self] in
        guard let self else { return }
        let time = self.outputTime()
        let hasNew = time.isNumeric && self.output.hasNewPixelBuffer(forItemTime: time)
        guard
          MonitorPlaybackDisplayLink.shouldPull(
            itemHasPresented: self.itemHasPresented, hasNewPixelBuffer: hasNew)
        else {
          if MonitorPlaybackDisplayLink.shouldPark(
            itemHasPresented: self.itemHasPresented, playerRate: self.player?.rate ?? 0)
          {
            let now = CACurrentMediaTime()
            let idleSince = self.idleSince ?? now
            self.idleSince = idleSince
            if MonitorPlaybackDisplayLink.parkIsDue(idleSince: idleSince, now: now) {
              // Resample the held picture so scopes match it after a paused seek.
              if self.effects.needsSample { self.schedulePull(force: true) }
              self.parkLink()
            }
          } else {
            self.idleSince = nil
          }
          return
        }
        self.idleSince = nil
        self.schedulePull(force: self.effects.needsSample && !self.itemHasPresented)
      }
    }

    /// Must run before `replaceCurrentItem`. Toggling a look later must not
    /// rebuild the player graph; same as Android `PlaybackFeedView`.
    @MainActor
    public func prepare(_ item: AVPlayerItem) {
      guard !closed, admitsSource() else { return }
      beginSourceChange()
      if !item.outputs.contains(where: { $0 === output }) {
        item.add(output)
      }
      boundItem = item
      displayLink?.isPaused = false
      // LUT chip stays on across next/prev. Drop the previous clip's metal
      // ownership and force a bake of this item; otherwise the toolbar
      // stays armed while the new picture is ungraded identity.
      host?.ciFeed.resetPresentation()
      if host != nil {
        applyLayerPlan(metalHasPresented: false)
      }
      output.requestNotificationOfMediaDataChange(withAdvanceInterval: 1.0 / 60.0)
    }

    /// Retire a clip as soon as Next/Previous starts loading, including a slow
    /// download. Keep the native host; old samples cannot become the new meter.
    @MainActor
    public func beginSourceChange() {
      guard !closed else { return }
      boundItem?.remove(output)
      boundItem = nil
      sourceFence.retire()
      // Clear after an admitted pull, on its queue. Never block Main on the
      // pull: it calls AVFoundation and Core Image, and a sync here hung
      // clip changes until the watchdog killed the app. New-item pulls queue behind this;
      // engine completions are asynchronous and are rejected by the item epoch.
      pullQueue.async { [weak self] in
        self?.lastBuffer = nil
        self?.pendingKick = false
        self?.loggedRaster = false
      }
      lastBackdropBuffer = nil
      if let sampleBus, sampleBus.isCurrent(sampleSource) {
        sampleBus.closeSource(sampleSource)
        sampleSource = sampleBus.openSource(.playback)
      }
      assistEngine.reset()
      if let sampleSource {
        declareClip(on: sampleSource)
        assistEngine.adopt(exposureCeiling: sampleSource.exposureCeiling)
      }
    }

    @MainActor private func declareClip(on source: LiveFrameSampleBus.Source) {
      guard let declaredClip, let clip = declaredClip(transfer) else { return }
      source.exposureCeiling.declare(clipByte: clip, for: transfer)
    }

    @MainActor public func reserveHostGeneration() -> Int {
      hostGeneration += 1
      return hostGeneration
    }

    @MainActor public var debugBoundHost: MonitorPlaybackFeedHost? { host }

    @MainActor public var debugItemHasPresented: Bool { itemHasPresented }

    /// Test seam: occupy the pull queue the way a slow pull does.
    public func debugOnPullQueue(_ body: @escaping @Sendable () -> Void) {
      pullQueue.async(execute: body)
    }

    @MainActor private var itemHasPresented: Bool {
      itemEpoch > 0 && presentedEpoch == itemEpoch
    }

    @MainActor
    public func attach(host: MonitorPlaybackFeedHost, player: AVPlayer) {
      guard !closed else { return }
      let sameHost = self.host === host
      guard
        MonitorPlaybackFeedHandoff.shouldAdoptHost(
          incomingGeneration: host.attachGeneration,
          currentGeneration: self.host?.attachGeneration,
          isSameHost: sameHost)
      else { return }
      if sameHost, !host.ciFeed.owns(pictureOwnership) { return }
      if !sameHost, let previous = self.host {
        previous.onDrawableReady = nil
        previous.ciFeed.onPresented = nil
      }
      if !sameHost { pictureOwnership = host.ciFeed.claimOwnership() }
      self.host = host
      self.player = player
      host.playerLayer.player = player
      host.ciFeed.onPresented = { [weak self] in
        guard let self else { return }
        let epoch = self.itemEpoch
        Task { @MainActor [weak self] in
          guard let self, self.itemEpoch == epoch else { return }
          self.adoptPresentedFeed()
        }
      }
      host.onDrawableReady = { [weak self] in
        Task { @MainActor in self?.pullIfMetalWaiting() }
      }
      if sameHost {
        applyLayerPlan(metalHasPresented: host.ciFeed.hasPresentedFrame)
      } else {
        applyLayerPlan(metalHasPresented: false)
        if let snapshot = pullSnapshot() {
          pullQueue.async { [weak self] in
            guard let self, self.sourceFence.accepts(snapshot.epoch),
              let buffer = self.lastBuffer
            else { return }
            self.submit(buffer, timeNs: 0, snapshot: snapshot)
          }
        }
      }
      pullIfMetalWaiting()
    }

    @MainActor
    public func detach(host: MonitorPlaybackFeedHost) {
      guard self.host === host else { return }
      if host.ciFeed.owns(pictureOwnership) {
        host.onDrawableReady = nil
        host.ciFeed.onPresented = nil
        host.ciFeed.releaseOwnership(pictureOwnership)
      }
      pictureOwnership = nil
      self.host = nil
    }

    @MainActor
    public func setEffects(
      _ effects: MonitorFrameEffects,
      transfer: MonitorTransfer,
      sampleBus: LiveFrameSampleBus
    ) {
      guard !closed else { return }
      let changed = self.effects != effects || self.transfer != transfer
      self.effects = effects
      self.transfer = transfer
      if self.sampleBus !== sampleBus || sampleSource == nil {
        sourceFence.retire(clearBuffer: false)
        self.sampleBus?.closeSource(sampleSource)
        self.sampleBus = sampleBus
        sampleSource = sampleBus.openSource(.playback)
        assistEngine.reset()
      }
      guard sampleBus.isCurrent(sampleSource) else { return }
      // A clip owns its calibration history independently of the held live picture.
      guard let sampleSource else { return }
      declareClip(on: sampleSource)
      assistEngine.adopt(exposureCeiling: sampleSource.exposureCeiling)
      if changed {
        sourceFence.retire(clearBuffer: false)
        host?.ciFeed.resetPresentDedup()
        assistEngine.updatePolicy(effects: effects.nativeAssistPolicy, transfer: transfer)
        lastOverlayOnly = effects.needsOverlayFeed
        lastUnmanagedBake = effects.replacesIdentityFeed
        // Drop the previous look (and its in-flight bake) so a stale LUT
        // cannot cover identity while zebra / peaking are still scheduling.
        presentedEpoch = itemEpoch &- 1
        host?.ciFeed.resetPresentation()
        applyLayerPlan(metalHasPresented: false)
      }
      if effects.needsSample || hdrDisplay() {
        startLink()
        // Same look on a new item: `changed` is false. Force-pull until
        // *this* item presents; not merely until some prior bake did.
        if MonitorPlaybackFeedHandoff.shouldForcePull(
          effectsChanged: changed,
          hasLastBuffer: sourceFence.hasBuffer,
          metalHasPresented: host?.ciFeed.hasPresentedFrame ?? false,
          itemHasPresented: itemHasPresented)
        {
          schedulePull(force: true)
        }
      } else if changed {
        stopLink()
        sampleBus.clearPlaybackSource(sampleSource)
      }
    }

    @MainActor
    public func shutdown() {
      guard !closed else { return }
      closed = true
      sourceFence.close()
      stopLink()
      boundItem?.remove(output)
      boundItem = nil
      pullQueue.async { [weak self] in self?.lastBuffer = nil }
      lastBackdropBuffer = nil
      sampleBus?.closeSource(sampleSource)
      sampleSource = nil
      assistEngine.reset()
      if let host, host.ciFeed.owns(pictureOwnership) {
        host.onDrawableReady = nil
        host.ciFeed.onPresented = nil
        host.ciFeed.invalidatePendingPresents()
        host.ciFeed.setOverlayChrome(false)
        host.ciFeed.isHidden = true
        host.playerLayer.isHidden = false
        host.ciFeed.releaseOwnership(pictureOwnership)
      }
      pictureOwnership = nil
      host = nil
      player = nil
      sampleBus = nil
    }

    @MainActor private func startLink() {
      displayLink?.isPaused = false
      guard displayLink == nil else { return }
      let link = CADisplayLink(
        target: linkTarget, selector: #selector(DisplayLinkTarget.tick))
      link.preferredFrameRateRange = MonitorPlaybackDisplayLink.pollRange
      link.add(to: .main, forMode: .common)
      displayLink = link
    }

    /// Called only by the visible backdrop's admitted 5 Hz job. The existing
    /// output is already attached to the player; this neither seeks nor starts
    /// a second output, display link, decoder or assist presentation pipeline.
    @MainActor
    public func backdropSource() -> CVPixelBuffer? {
      guard !closed, admitsSource(), boundItem != nil else { return nil }
      if effects.needsSample { return sampleBus?.playbackSourcePixelBuffer }
      let time = outputTime()
      guard time.isNumeric else { return lastBackdropBuffer }
      if output.hasNewPixelBuffer(forItemTime: time),
        let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
      {
        lastBackdropBuffer = buffer
      }
      return lastBackdropBuffer
    }

    @MainActor private func stopLink() {
      displayLink?.invalidate()
      displayLink = nil
    }

    @MainActor private func parkLink() {
      idleSince = nil
      guard let displayLink, !displayLink.isPaused else { return }
      displayLink.isPaused = true
      output.requestNotificationOfMediaDataChange(withAdvanceInterval: 1.0 / 60.0)
    }

    /// New item is current and (usually) playing. Kick the output; the first
    /// `prepare` pull often ran before a pixel buffer existed.
    @MainActor
    public func noteItemReady() {
      guard !closed, admitsSource(), effects.needsSample || hdrDisplay() else { return }
      displayLink?.isPaused = false
      output.requestNotificationOfMediaDataChange(withAdvanceInterval: 1.0 / 60.0)
      schedulePull(force: true)
    }

    private struct PullSnapshot: @unchecked Sendable {
      let epoch: UInt64
      let item: AVPlayerItem
      let player: AVPlayer?
      let effects: MonitorFrameEffects
      let transfer: MonitorTransfer
      let publicationSource: LiveFrameSampleBus.Source?
      let hdrDisplay: Bool
    }
    @MainActor private func pullSnapshot() -> PullSnapshot? {
      guard !closed, admitsSource(), let boundItem else { return nil }
      return .init(
        epoch: itemEpoch, item: boundItem, player: player, effects: effects,
        transfer: transfer, publicationSource: sampleSource, hdrDisplay: hdrDisplay())
    }
    @MainActor private func schedulePull(force: Bool) {
      guard let snapshot = pullSnapshot() else { return }
      pullQueue.async { [weak self] in
        guard let self, self.sourceFence.accepts(snapshot.epoch) else { return }
        self.pull(force: force, snapshot: snapshot)
      }
    }

    @MainActor
    private func pullIfMetalWaiting() {
      guard effects.needsSample || hdrDisplay(), !itemHasPresented else { return }
      schedulePull(force: true)
    }

    private func pull(force: Bool, snapshot: PullSnapshot) {
      guard sourceFence.accepts(snapshot.epoch),
        snapshot.effects.needsSample || snapshot.hdrDisplay
      else { return }
      let time = outputTime(item: snapshot.item, player: snapshot.player)
      let timeNs = Self.timeNs(time)
      if time.isNumeric, output.hasNewPixelBuffer(forItemTime: time),
        let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
      {
        let working = workingRaster.prepared(buffer)
        if !loggedRaster {
          loggedRaster = true
          let w = CVPixelBufferGetWidth(working)
          let h = CVPixelBufferGetHeight(working)
          let srcW = CVPixelBufferGetWidth(buffer)
          journal(
            "media: grade \(w)x\(h) from \(srcW)x\(CVPixelBufferGetHeight(buffer)) \(LiveFrameTap.fourCC(buffer))"
          )
        }
        guard sourceFence.markBuffer(epoch: snapshot.epoch) else { return }
        lastBuffer = working
        submit(working, timeNs: timeNs, snapshot: snapshot)
        Task { @MainActor [weak self] in
          guard let self, self.admitsSource(), self.sourceFence.accepts(snapshot.epoch)
          else { return }
          self.sourceAdvanced()
        }
        return
      }
      if let lastBuffer, force {
        submit(lastBuffer, timeNs: timeNs, snapshot: snapshot)
        return
      }
      // Output added after decode has started (or the item is parked) holds
      // no pixel buffer until a seek. Live never has this; VT already owns the frame.
      if force, lastBuffer == nil, !pendingKick, let player = snapshot.player {
        let seekTime = player.currentTime()
        // A newly attached or failed remote item can report invalid or
        // indefinite time. AVPlayer raises an Objective-C exception if
        // that value is used as a seek target; wait for the ready callback.
        guard player.currentItem === snapshot.item,
          snapshot.item.status == .readyToPlay, seekTime.isNumeric
        else { return }
        pendingKick = true
        Task { @MainActor [weak self] in
          guard let self, !self.closed, self.admitsSource(),
            self.sourceFence.accepts(snapshot.epoch),
            self.boundItem === snapshot.item, player.currentItem === snapshot.item,
            snapshot.item.status == .readyToPlay
          else { return }
          // Item replacement is Main-owned too. Validate and issue the native action on
          // that actor so retirement cannot land between admission and seek on another queue.
          player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] _ in
            guard let self, self.sourceFence.accepts(snapshot.epoch) else { return }
            self.pullQueue.async { [weak self] in
              guard let self, self.sourceFence.accepts(snapshot.epoch) else { return }
              self.pendingKick = false
              self.pull(force: true, snapshot: snapshot)
            }
          }
        }
      }
    }

    @MainActor private func outputTime() -> CMTime {
      outputTime(item: boundItem, player: player)
    }
    private func outputTime(item: AVPlayerItem?, player: AVPlayer?) -> CMTime {
      if let player, player.rate != 0 {
        return output.itemTime(forHostTime: CACurrentMediaTime())
      }
      return item?.currentTime() ?? player?.currentTime() ?? .zero
    }

    private func submit(_ buffer: CVPixelBuffer, timeNs: Int64, snapshot: PullSnapshot) {
      // Only enqueue engine work while this source is admitted. Retirement takes the same
      // short lock before enqueueing reset, so old sampling cannot follow the new reset.
      sourceFence.withCurrent(snapshot.epoch) {
        assistEngine.submit(
          buffer, effects: snapshot.effects.nativeAssistPolicy,
          transfer: snapshot.transfer, timeNs: timeNs == 0 ? nil : timeNs
        ) { [weak self] result in
          Task { @MainActor [weak self] in
            self?.present(
              result, sourceEpoch: snapshot.epoch,
              publicationSource: snapshot.publicationSource)
          }
        }
      }
    }

    private static func timeNs(_ time: CMTime) -> Int64 {
      guard time.isValid, !time.isIndefinite else { return 0 }
      let seconds = CMTimeGetSeconds(time)
      guard seconds.isFinite, seconds >= 0 else { return 0 }
      return Int64(seconds * 1_000_000_000)
    }

    @MainActor
    private func present(
      _ result: MonitorAssistEngine.Result, sourceEpoch: UInt64,
      publicationSource: LiveFrameSampleBus.Source?
    ) {
      guard !closed, admitsSource(), boundItem != nil, sourceEpoch == itemEpoch else {
        return
      }
      guard let sampleBus,
        sampleBus.publish(
          publicationSource,
          source: result.shouldPresent ? result.source : nil, transfer: result.transfer,
          bundle: result.bundle)
      else { return }
      // Sample observers may synchronously replace the item, content authority or host.
      // Recheck after publication before mutating presentation state for this result.
      guard !closed, admitsSource(), boundItem != nil, sourceEpoch == itemEpoch,
        sampleBus.isCurrent(publicationSource),
        let host, host.ciFeed.owns(pictureOwnership), result.shouldPresent
      else { return }
      lastOverlayOnly = result.overlayOnly
      lastUnmanagedBake = result.unmanagedBake
      let feed = host.ciFeed
      if hdrDisplay(), !effects.needsGPUFeed {
        let identity = CIImage(cvPixelBuffer: result.source)
        if feed.display(identity, unmanaged: false, overlay: false, timeNs: result.timeNs) {
          return
        }
      }
      if !result.needsGPU || !effects.needsGPUFeed {
        if MonitorPlaybackFeedHandoff.sourceReadyWithoutMetal(
          needsGPUFeed: effects.needsGPUFeed, hdrDisplay: hdrDisplay())
        {
          presentedEpoch = itemEpoch
        }
        applyLayerPlan(metalHasPresented: false)
        return
      }
      if result.overlayOnly {
        let painted = feed.display(
          result.output, unmanaged: true, overlay: true, timeNs: result.timeNs)
        if !painted {
          feed.setOverlayChrome(false)
          feed.isHidden = true
        }
        host.playerLayer.isHidden = false
        return
      }
      // Do not unhide Metal here; that is an empty opaque plate over the
      // player. `display` schedules the bake; `presentLatestBake` unhides
      // only with a texture in hand. Player stays underlay.
      let unmanaged = MonitorPlaybackFeedHandoff.presentUnmanaged(
        overlay: false, unmanagedBake: result.unmanagedBake)
      let painted =
        feed.display(
          result.output, unmanaged: unmanaged, overlay: false, timeNs: result.timeNs)
        || feed.display(
          result.identity, unmanaged: false, overlay: false, timeNs: result.timeNs)
      if !painted {
        feed.setOverlayChrome(false)
        feed.isHidden = true
        host.playerLayer.isHidden = false
      }
    }

    @MainActor
    private func adoptPresentedFeed() {
      guard !closed, admitsSource(), host?.ciFeed.owns(pictureOwnership) == true else {
        return
      }
      presentedEpoch = itemEpoch
      guard let feed = host?.ciFeed else { return }
      maybeLogPresentHealth()
      if lastOverlayOnly || effects.needsOverlayFeed {
        applyLayerPlan(metalHasPresented: feed.hasPresentedFrame)
        return
      }
      applyLayerPlan(metalHasPresented: replaceOwnsPicture)
    }

    @MainActor
    private func maybeLogPresentHealth() {
      guard effects.needsGPUFeed, let feed = host?.ciFeed else { return }
      let now = Date()
      if let last = lastPresentHealthLogAt, now.timeIntervalSince(last) < 2 { return }
      lastPresentHealthLogAt = now
      journal("media: \(feed.debugLine)")
    }

    @MainActor private var replaceOwnsPicture: Bool {
      guard let feed = host?.ciFeed else { return false }
      return MonitorPlaybackFeedHandoff.replaceOwnsPicture(
        hasPresentedFrame: feed.hasPresentedFrame,
        lastPresentWasOverlay: feed.lastPresentWasOverlay)
    }

    @MainActor
    private func applyLayerPlan(metalHasPresented: Bool) {
      guard !closed, admitsSource(), let host, host.ciFeed.owns(pictureOwnership) else {
        return
      }
      let plan = MonitorPlaybackFeedHandoff.plan(
        effects: effects,
        overlayOnly: lastOverlayOnly,
        unmanagedBake: lastUnmanagedBake,
        metalHasPresented: metalHasPresented,
        hdrDisplay: hdrDisplay())
      host.playerLayer.isHidden = !plan.showPlayer
      if plan.showFeed {
        host.ciFeed.isHidden = false
      } else {
        // Clear ownership so `attach` cannot unhide an empty plate.
        // Do not bump presentGeneration; SwiftUI calls attach every pass
        // and would cancel the LUT bake that `present` just scheduled.
        host.ciFeed.hideForLayerPlan()
      }
    }
  }

  /// Same stacking as live `DisplayLayerView`: identity layer and Metal are
  /// siblings under a plain UIView. `CAMetalLayer` nested in `AVPlayerLayer`
  /// (this view's old `layerClass`) presents LUT replace as a black plate;
  /// transparent zebra / peaking overlays still showed through.
  open class MonitorPlaybackFeedHost: UIView {
    public let playerLayer = AVPlayerLayer()
    public let ciFeed: MonitorPictureHost
    private let configurePlayerLayer: @MainActor (AVPlayerLayer) -> Void
    public var onDrawableReady: (() -> Void)?
    /// SwiftUI identity for this representable. A lower generation is the
    /// departing next/prev twin and must not steal `MonitorPlaybackFeedSession`.
    public var attachGeneration = 0

    public init(
      frame: CGRect = .zero, picture: MonitorPictureHost,
      configurePlayerLayer: @escaping @MainActor (AVPlayerLayer) -> Void = { _ in }
    ) {
      ciFeed = picture
      self.configurePlayerLayer = configurePlayerLayer
      super.init(frame: frame)
      backgroundColor = .black
      isUserInteractionEnabled = false
      playerLayer.videoGravity = .resizeAspect
      layer.addSublayer(playerLayer)
      addSubview(ciFeed)
      ciFeed.isUserInteractionEnabled = false
    }

    public required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    public override func didMoveToWindow() {
      super.didMoveToWindow()
      noteDrawableReady()
    }

    public override func layoutSubviews() {
      super.layoutSubviews()
      playerLayer.frame = bounds
      ciFeed.frame = bounds
      ciFeed.syncHDRDisplay()
      configurePlayerLayer(playerLayer)
      noteDrawableReady()
    }

    private func noteDrawableReady() {
      let ready = window != nil && bounds.width > 1 && bounds.height > 1
      ciFeed.isEnabled = ready
      if ready { onDrawableReady?() }
    }
  }

  extension MonitorPlaybackFeedSession: AVPlayerItemOutputPullDelegate {
    public nonisolated func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
      Task { @MainActor [weak self] in
        guard let self, !self.closed else { return }
        self.schedulePull(force: true)
        self.displayLink?.isPaused = false
      }
    }
  }

  /// Protects only source admission and short engine enqueueing, never AVFoundation or rendering.
  private final class PlaybackPullFence: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var closed = false
    private var buffer = false
    var epoch: UInt64 { lock.withLock { revision } }
    var hasBuffer: Bool { lock.withLock { buffer } }
    func retire(clearBuffer: Bool = true) {
      lock.withLock {
        revision &+= 1
        if clearBuffer { buffer = false }
      }
    }
    func close() {
      lock.withLock {
        closed = true
        revision &+= 1
        buffer = false
      }
    }
    func accepts(_ epoch: UInt64) -> Bool { lock.withLock { !closed && epoch == revision } }
    func markBuffer(epoch: UInt64) -> Bool {
      lock.withLock {
        guard !closed, epoch == revision else { return false }
        buffer = true
        return true
      }
    }
    func withCurrent(_ epoch: UInt64, _ body: () -> Void) {
      lock.withLock { if !closed, epoch == revision { body() } }
    }
  }

  @MainActor private final class DisplayLinkTarget: NSObject {
    var handler: () -> Void = {}
    @objc func tick() { handler() }
  }

  /// AVPlayerItemVideoOutput frames are Metal IOSurface + Rec.709 attachments.
  /// Live unmanaged LUT is encoded camera codes without those tags; cloning
  /// onto CPU BGRA is the same input the compositor tests already grade.
  public enum MonitorPlaybackPixelCopy {
    private static let copyContext = CIContext(options: MonitorWorkingSpace.contextOptions)

    public static func untaggedBGRA(_ buffer: CVPixelBuffer) -> CVPixelBuffer {
      let width = CVPixelBufferGetWidth(buffer)
      let height = CVPixelBufferGetHeight(buffer)
      guard width > 1, height > 1 else { return buffer }
      var clone: CVPixelBuffer?
      let status = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &clone)
      guard status == kCVReturnSuccess, let clone else { return buffer }
      if CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
        blitBGRA(from: buffer, to: clone)
      {
        return clone
      }
      let image = CIImage(cvPixelBuffer: buffer, options: MonitorWorkingSpace.imageOptions)
      copyContext.render(
        image, to: clone,
        bounds: CGRect(x: 0, y: 0, width: width, height: height),
        colorSpace: nil)
      return clone
    }

    private static func blitBGRA(from source: CVPixelBuffer, to dest: CVPixelBuffer) -> Bool {
      guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else {
        return false
      }
      defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
      guard CVPixelBufferLockBaseAddress(dest, []) == kCVReturnSuccess else { return false }
      defer { CVPixelBufferUnlockBaseAddress(dest, []) }
      guard let src = CVPixelBufferGetBaseAddress(source),
        let dst = CVPixelBufferGetBaseAddress(dest)
      else { return false }
      let height = CVPixelBufferGetHeight(source)
      let width = CVPixelBufferGetWidth(source)
      let srcStride = CVPixelBufferGetBytesPerRow(source)
      let dstStride = CVPixelBufferGetBytesPerRow(dest)
      let rowBytes = min(srcStride, dstStride, width * 4)
      for y in 0..<height {
        dst.advanced(by: y * dstStride).copyMemory(
          from: src.advanced(by: y * srcStride), byteCount: rowBytes)
      }
      return true
    }
  }

#endif
