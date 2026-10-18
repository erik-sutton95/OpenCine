#if canImport(UIKit) && canImport(AVFoundation)
    import AVFoundation
    import Foundation
    import OpenCineMedia

    /// Actual AVPlayer item, observer and output lifetime. Covers pause transport without rebuilding
    /// this owner or its retained picture host. Clip changes retire every previous native callback.
    @MainActor public final class MonitorApplePlaybackOwner: NSObject, MonitorPlaybackPort {
        public let player: AVPlayer
        public let feed: MonitorPlaybackFeedSession
        public var onEvent:
            (@MainActor @Sendable (MonitorPlaybackItemToken, MonitorPlaybackEvent) -> Void)?
        public var onItemChanged: (@MainActor (AVPlayerItem?) -> Void)?
        /// Optional host content/root authority. It executes on Main, at the existing native
        /// admission boundary; renderer queues continue to use the retired source epoch.
        public var sourceAdmission: (@MainActor @Sendable () -> Bool)? {
            didSet { feed.sourceAdmission = sourceAdmission }
        }
        private func admitsSource() -> Bool { sourceAdmission?() ?? true }
        private var token: MonitorPlaybackItemToken?
        private var item: AVPlayerItem?
        private var preparation = UUID()
        private var waiter: CheckedContinuation<Void, Error>?
        private var statusObserver: NSKeyValueObservation?
        private var transportObserver: NSKeyValueObservation?
        private var timeObserver: Any?
        private var endObserver: NSObjectProtocol?
        private var timeoutTask: Task<Void, Never>?
        private var metadataTask: Task<Void, Never>?
        private var preparationReturned = false
        private var reportedFailure = false
        private var closed = false

        public init(player: AVPlayer = AVPlayer(), feed: MonitorPlaybackFeedSession) {
            self.player = player
            self.feed = feed
            super.init()
        }
        public func retireItem(for token: MonitorPlaybackItemToken) {
            guard !closed, admitsSource(),
                self.token == nil || token.revision == 0
                    || (self.token?.owner == token.owner
                        && token.revision >= (self.token?.revision ?? 0))
            else { return }
            self.token = token
            retireObservers()
            guard !closed, admitsSource(), self.token == token else { return }
            feed.beginSourceChange()
            guard !closed, admitsSource(), self.token == token else { return }
            player.pause()
            guard !closed, admitsSource(), self.token == token else { return }
            player.replaceCurrentItem(with: nil)
            guard !closed, admitsSource(), self.token == token else { return }
            item = nil
            onItemChanged?(nil)
        }
        public func prepare(
            _ file: MonitorPlaybackItem, token: MonitorPlaybackItemToken,
            readyTimeout: Duration?
        ) async throws -> MonitorPlaybackMetadata {
            guard !closed, admitsSource(), self.token == token else {
                throw MonitorPlaybackError.retired
            }
            retireObservers()
            guard !closed, admitsSource(), self.token == token else {
                throw MonitorPlaybackError.retired
            }
            let request = UUID()
            preparation = request
            let asset = AVURLAsset(
                url: file.url,
                options: [
                    "AVURLAssetOutOfBandMIMETypeKey": file.mimeType,
                    AVURLAssetAllowsCellularAccessKey: false,
                    "AVURLAssetHTTPHeaderFieldsKey": ["Accept": "*/*"],
                ])
            let item = AVPlayerItem(asset: asset)
            self.item = item
            // Output must be attached before decode starts; parked frames otherwise arrive too late.
            feed.prepare(item)
            guard current(token, request: request), !Task.isCancelled else {
                throw MonitorPlaybackError.retired
            }
            statusObserver = item.observe(\.status, options: [.new]) {
                [weak self, weak item] _, _ in
                Task { @MainActor in
                    guard let self, let item, self.current(token, request: request),
                        self.item === item, self.player.currentItem === item
                    else { return }
                    self.completeReadiness(item, token: token, request: request)
                }
            }
            player.replaceCurrentItem(with: item)
            guard current(token, request: request), !Task.isCancelled else {
                throw MonitorPlaybackError.retired
            }
            player.automaticallyWaitsToMinimizeStalling = file.isRemote
            onItemChanged?(item)
            guard current(token, request: request), !Task.isCancelled else {
                throw MonitorPlaybackError.retired
            }
            onEvent?(token, .itemInstalled)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (waiter: CheckedContinuation<Void, Error>) in
                    guard current(token, request: request), !Task.isCancelled else {
                        waiter.resume(throwing: MonitorPlaybackError.retired)
                        return
                    }
                    self.waiter = waiter
                    if let readyTimeout {
                        timeoutTask = Task { [weak self] in
                            do { try await Task.sleep(for: readyTimeout) } catch { return }
                            guard let self, self.current(token, request: request) else { return }
                            self.finishReadiness(
                                .failure(
                                    MonitorPlaybackError.nativeFailure("Clip did not become ready.")
                                ))
                        }
                    }
                    completeReadiness(item, token: token, request: request)
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, self.current(token, request: request) else { return }
                    self.finishReadiness(.failure(MonitorPlaybackError.retired))
                }
            }
            guard current(token, request: request), !Task.isCancelled else {
                throw MonitorPlaybackError.retired
            }
            guard item.status != .failed else {
                throw MonitorPlaybackError.nativeFailure(
                    item.error?.localizedDescription ?? "Could not open that clip.")
            }
            installObservers(item: item, token: token, request: request)
            feed.noteItemReady()
            guard current(token, request: request), !Task.isCancelled else {
                throw MonitorPlaybackError.retired
            }
            // Readiness starts transport first. Track probing follows without delaying the first picture.
            metadataTask = Task { [weak self, weak item] in
                guard let self, let item, self.current(token, request: request), !Task.isCancelled
                else { return }
                let facts = await Self.metadata(item.asset, duration: item.duration)
                guard self.current(token, request: request), self.item === item, !Task.isCancelled
                else { return }
                self.metadataTask = nil
                self.onEvent?(token, .metadata(facts))
            }
            guard current(token, request: request), self.item === item,
                player.currentItem === item, !Task.isCancelled
            else { throw MonitorPlaybackError.retired }
            guard item.status != .failed else {
                throw MonitorPlaybackError.nativeFailure(
                    item.error?.localizedDescription ?? "Could not open that clip.")
            }
            preparationReturned = true
            return .init(duration: CMTimeGetSeconds(item.duration))
        }
        private func current(_ token: MonitorPlaybackItemToken, request: UUID) -> Bool {
            !closed && admitsSource() && self.token == token && preparation == request
        }
        /// Actual native temporal extent for this prepared item, independent of transfer bytes.
        public func bufferedThroughSeconds(token: MonitorPlaybackItemToken) -> Double? {
            let request = preparation
            guard preparationReturned, current(token, request: request), let item,
                player.currentItem === item, item.status == .readyToPlay
            else { return nil }
            guard current(token, request: request), self.item === item,
                player.currentItem === item
            else { return nil }
            let ranges = item.loadedTimeRanges
            guard current(token, request: request), self.item === item,
                player.currentItem === item
            else { return nil }
            return ranges.map { CMTimeGetSeconds(CMTimeRangeGetEnd($0.timeRangeValue)) }
                .filter { $0.isFinite && $0 >= 0 }.max()
        }
        private func completeReadiness(
            _ item: AVPlayerItem, token: MonitorPlaybackItemToken, request: UUID
        ) {
            switch item.status {
            case .readyToPlay: finishReadiness(.success(()))
            case .failed:
                let message = item.error?.localizedDescription ?? "Could not open that clip."
                if !preparationReturned {
                    finishReadiness(.failure(MonitorPlaybackError.nativeFailure(message)))
                } else {
                    guard !reportedFailure, current(token, request: request), self.item === item,
                        player.currentItem === item
                    else { return }
                    reportedFailure = true
                    onEvent?(token, .failed(message))
                }
            default: break
            }
        }
        private func finishReadiness(_ result: Result<Void, Error>) {
            timeoutTask?.cancel()
            timeoutTask = nil
            let waiter = waiter
            self.waiter = nil
            waiter?.resume(with: result)
        }
        private func installObservers(
            item: AVPlayerItem, token: MonitorPlaybackItemToken, request: UUID
        ) {
            transportObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) {
                [weak self, weak item] _, _ in
                Task { @MainActor in
                    guard let self, let item, self.current(token, request: request),
                        self.item === item, self.player.currentItem === item
                    else { return }
                    let transport: MonitorPlaybackTransportState?
                    switch self.player.timeControlStatus {
                    case .paused: transport = .paused
                    case .waitingToPlayAtSpecifiedRate: transport = .waiting
                    case .playing: transport = .playing
                    @unknown default: transport = nil
                    }
                    guard self.current(token, request: request), self.item === item,
                        self.player.currentItem === item
                    else { return }
                    self.onEvent?(token, .transport(transport))
                }
            }
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
            ) { [weak self] time in
                Task { @MainActor in
                    guard let self, self.current(token, request: request) else { return }
                    let seconds = CMTimeGetSeconds(time)
                    self.onEvent?(
                        token, .position(seconds.isFinite && seconds >= 0 ? seconds : nil))
                }
            }
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.current(token, request: request) else { return }
                    self.onEvent?(token, .ended)
                }
            }
        }
        private func retireObservers() {
            preparation = UUID()
            preparationReturned = false
            reportedFailure = false
            metadataTask?.cancel()
            metadataTask = nil
            finishReadiness(.failure(MonitorPlaybackError.retired))
            statusObserver = nil
            transportObserver = nil
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            timeObserver = nil
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = nil
        }
        public func play(rate: Double, token: MonitorPlaybackItemToken) {
            guard !closed, admitsSource(), self.token == token, rate.isFinite, rate > 0 else {
                return
            }
            player.playImmediately(atRate: Float(rate))
        }
        public func pause(token: MonitorPlaybackItemToken) {
            guard !closed, admitsSource(), self.token == token else { return }
            player.pause()
        }
        public func seek(seconds: Double, tolerance: Double, token: MonitorPlaybackItemToken) async
            -> Bool
        {
            guard !closed, admitsSource(), self.token == token, seconds.isFinite, seconds >= 0
            else { return false }
            let request = preparation
            let target = CMTime(seconds: seconds, preferredTimescale: 600)
            let tolerance = CMTime(seconds: max(0, tolerance), preferredTimescale: 600)
            let completed = await withCheckedContinuation { continuation in
                player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) {
                    completed in
                    continuation.resume(returning: completed)
                }
            }
            return current(token, request: request) && !Task.isCancelled && completed
        }
        public func setMuted(_ muted: Bool, token: MonitorPlaybackItemToken) {
            guard !closed, admitsSource(), self.token == token else { return }
            player.isMuted = muted
        }
        public func close(token: MonitorPlaybackItemToken) {
            guard !closed, self.token?.owner == token.owner else { return }
            closed = true
            self.token = nil
            onEvent = nil
            retireObservers()
            player.pause()
            player.replaceCurrentItem(with: nil)
            item = nil
            onItemChanged?(nil)
            feed.shutdown()
        }
        private static func metadata(_ asset: AVAsset, duration: CMTime) async
            -> MonitorPlaybackMetadata
        {
            let durationSeconds = CMTimeGetSeconds(duration)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
                return .init(duration: durationSeconds)
            }
            let nominal = try? await track.load(.nominalFrameRate)
            let minimum = try? await track.load(.minFrameDuration)
            let natural = try? await track.load(.naturalSize)
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let display = natural.map { CGRect(origin: .zero, size: $0).applying(transform) }
            return .init(
                duration: durationSeconds, width: display.map { Double(abs($0.width)) },
                height: display.map { Double(abs($0.height)) },
                conform: MonitorConformPreview.probe(
                    nominalFrameRate: nominal.map(Double.init),
                    minFrameDurationSeconds: minimum.map(CMTimeGetSeconds)))
        }
    }
#endif
