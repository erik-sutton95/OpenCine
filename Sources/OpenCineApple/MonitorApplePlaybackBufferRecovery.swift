#if canImport(AVFoundation) && !os(watchOS)
    import AVFoundation
    import Foundation
    import OpenCineMedia

    /// Native recovery for a resource-loader-backed item with automatic waiting disabled.
    /// It retains only the last admitted Play rate. Pause, close and interruption retire it
    /// before queued native callbacks can resume a starved buffer.
    @MainActor public final class MonitorApplePlaybackBufferRecovery {
        private let player: AVPlayer
        private let item: AVPlayerItem
        private let isCurrent: @MainActor @Sendable () -> Bool
        private let onTransport: @MainActor @Sendable (MonitorPlaybackTransportState?) -> Void
        private var bufferObservation: NSKeyValueObservation?
        private var statusObservation: NSKeyValueObservation?
        private var requestedRate: Float?
        private var waitingForBuffer = false
        private var closed = false
        #if os(iOS)
            private var interruptionObserver: NSObjectProtocol?
        #endif

        /// Bind one native item to its host's captured source admission and transport observer.
        public init(
            player: AVPlayer, item: AVPlayerItem,
            isCurrent: @escaping @MainActor @Sendable () -> Bool,
            onTransport: @escaping @MainActor @Sendable (MonitorPlaybackTransportState?) -> Void
        ) {
            self.player = player
            self.item = item
            self.isCurrent = isCurrent
            self.onTransport = onTransport
            bufferObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) {
                [weak self] _, change in
                guard let empty = change.newValue else { return }
                Task { @MainActor in self?.bufferChanged(observedEmpty: empty) }
            }
            statusObservation = player.observe(\.timeControlStatus, options: [.new]) {
                [weak self] _, _ in
                Task { @MainActor in self?.publishTransport() }
            }
            #if os(iOS)
                interruptionObserver = NotificationCenter.default.addObserver(
                    forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
                ) { [weak self] notification in
                    guard
                        (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                            == AVAudioSession.InterruptionType.began.rawValue
                    else { return }
                    MainActor.assumeIsolated {
                        self?.requestedRate = nil
                        self?.waitingForBuffer = false
                        self?.publishTransport()
                    }
                }
            #endif
        }

        /// Retain a finite positive rate only for the still-current item and source.
        /// Native buffer refill may resume this intent until Pause, interruption or close.
        public func play(rate: Double) {
            guard rate.isFinite, rate > 0, Float(rate).isFinite, active() else { return }
            requestedRate = Float(rate)
            waitingForBuffer = item.isPlaybackBufferEmpty
            player.rate = Float(rate)
            publishTransport()
        }

        /// Clear retained Play intent before native pause or any reentrant host callback.
        public func pause() {
            requestedRate = nil
            waitingForBuffer = false
            guard active() else { return }
            player.pause()
            publishTransport()
        }

        /// Detach before the caller replaces/releases its item. Closing sends no player command.
        public func close() {
            closed = true
            requestedRate = nil
            waitingForBuffer = false
            bufferObservation = nil
            statusObservation = nil
            #if os(iOS)
                if let interruptionObserver {
                    NotificationCenter.default.removeObserver(interruptionObserver)
                }
                interruptionObserver = nil
            #endif
        }

        private func active() -> Bool {
            guard !closed, player.currentItem === item else { return false }
            let accepted = isCurrent()
            return accepted && !closed && player.currentItem === item
        }

        private func bufferChanged(observedEmpty: Bool) {
            guard active(), let rate = requestedRate else { return }
            // Preserve a starvation edge even if native refill precedes MainActor delivery.
            if observedEmpty || item.isPlaybackBufferEmpty {
                waitingForBuffer = true
                publishTransport()
            }
            if waitingForBuffer, !item.isPlaybackBufferEmpty {
                // Publication can synchronously pause, retire or replace this exact item.
                publishTransport()
                guard active(), requestedRate == rate, waitingForBuffer,
                    !item.isPlaybackBufferEmpty
                else { return }
                waitingForBuffer = false
                player.rate = rate
                publishTransport()
            }
        }

        private func publishTransport() {
            guard active() else { return }
            let state: MonitorPlaybackTransportState?
            if item.status != .readyToPlay {
                state = nil
            } else if waitingForBuffer, requestedRate != nil {
                state = .waiting
            } else {
                switch player.timeControlStatus {
                case .paused: state = .paused
                case .waitingToPlayAtSpecifiedRate: state = .waiting
                case .playing: state = .playing
                @unknown default: state = nil
                }
            }
            guard active() else { return }
            onTransport(state)
        }
    }
#endif
