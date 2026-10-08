#if os(iOS) || os(watchOS)
    #if canImport(WatchConnectivity)
        import Foundation
        import OpenCineRelay
        import SwiftUI
        import UIKit
        import WatchConnectivity

        /// Mutable producer identity is read on the SDK queue before its actor hop. A retired SDK
        /// delegate owns a different, permanently disarmed gate and cannot borrow its successor's window.
        private final class WatchCallbackWindow: @unchecked Sendable {
            private let lock = NSLock()
            private var window: UUID?
            init(_ window: UUID) { self.window = window }
            func read() -> UUID? {
                lock.lock()
                defer { lock.unlock() }
                return window
            }
            func publish(_ value: UUID?) {
                lock.lock()
                window = value
                lock.unlock()
            }
        }

        private struct WatchSDKBox<Value>: @unchecked Sendable { let value: Value }

        private final class WatchSDKDelegate: NSObject, WCSessionDelegate, @unchecked Sendable {
            let gate: WatchCallbackWindow
            let immediateReply: Bool
            let receive: @Sendable (Data, UUID, (@Sendable (Data) -> Void)?) -> Void
            let link: @Sendable (Bool, Bool, UUID) -> Void
            let context: @Sendable (Data, UUID) -> Void
            init(
                window: UUID, immediateReply: Bool,
                receive: @escaping @Sendable (Data, UUID, (@Sendable (Data) -> Void)?) -> Void,
                link: @escaping @Sendable (Bool, Bool, UUID) -> Void,
                context: @escaping @Sendable (Data, UUID) -> Void
            ) {
                gate = WatchCallbackWindow(window)
                self.immediateReply = immediateReply
                self.receive = receive
                self.link = link
                self.context = context
            }
            func session(
                _ session: WCSession,
                activationDidCompleteWith activationState: WCSessionActivationState,
                error: Error?
            ) { changed(session) }
            func sessionReachabilityDidChange(_ session: WCSession) { changed(session) }
            private func changed(_ session: WCSession) {
                guard let window = gate.read() else { return }
                link(session.activationState == .activated, session.isReachable, window)
            }
            func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
                guard let window = gate.read() else { return }
                receive(messageData, window, nil)
            }
            func session(
                _ session: WCSession, didReceiveMessageData messageData: Data,
                replyHandler: @escaping (Data) -> Void
            ) {
                // A preview ACK measures link time, before UIImage decoding or UI scheduling.
                if immediateReply { replyHandler(Data()) }
                guard let window = gate.read() else {
                    if !immediateReply { replyHandler(Data()) }
                    return
                }
                let box = WatchSDKBox(value: replyHandler)
                let reply: (@Sendable (Data) -> Void)?
                if immediateReply {
                    reply = nil
                } else {
                    reply = { box.value($0) }
                }
                receive(messageData, window, reply)
            }
            func session(
                _ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]
            ) {
                guard let window = gate.read(),
                    let data = applicationContext[WatchRelayContext.stateKey] as? Data
                else { return }
                context(data, window)
            }
            #if os(iOS)
                func sessionDidBecomeInactive(_ session: WCSession) {}
                func sessionDidDeactivate(_ session: WCSession) {
                    guard gate.read() != nil else { return }
                    session.activate()
                }
            #endif
        }

        @MainActor private final class WatchSDKPort {
            let session: WCSession? = WCSession.isSupported() ? .default : nil
            private var delegate: WatchSDKDelegate?
            var activated: Bool { session?.activationState == .activated }
            var reachable: Bool { session?.isReachable == true }
            var hasCompanion: Bool {
                #if os(iOS)
                    session?.isPaired == true && session?.isWatchAppInstalled == true
                #else
                    session != nil
                #endif
            }
            func arm(_ delegate: WatchSDKDelegate) {
                self.delegate?.gate.publish(nil)
                self.delegate = delegate
                guard let session else { return }
                session.delegate = delegate
                if session.activationState != .activated { session.activate() }
            }
            func publish(_ window: UUID) { delegate?.gate.publish(window) }
            func close() {
                delegate?.gate.publish(nil)
                if let session, session.delegate === delegate { session.delegate = nil }
                delegate = nil
            }
            func send(
                _ data: Data, reply: (@MainActor (Data) -> Void)?, failure: (@MainActor () -> Void)?
            ) {
                guard let session else {
                    failure?()
                    return
                }
                let replyBox = WatchSDKBox(value: reply)
                let errorBox = WatchSDKBox(value: failure)
                let replyHandler: (@Sendable (Data) -> Void)?
                if reply == nil {
                    replyHandler = nil
                } else {
                    replyHandler = { data in
                        Task<Void, Never> { @MainActor in
                            replyBox.value?(data)
                        }
                    }
                }
                let errorHandler: @Sendable (Error) -> Void = { _ in
                    Task<Void, Never> { @MainActor in
                        errorBox.value?()
                    }
                }
                session.sendMessageData(
                    data, replyHandler: replyHandler, errorHandler: errorHandler)
            }
            func updateContext(_ data: Data) {
                try? session?.updateApplicationContext([WatchRelayContext.stateKey: data])
            }
        }

        /// Actual WatchConnectivity phone owner shared by two deployed codecs. Only the native picture
        /// producer varies; the SDK delegate, source admission, pending work and control runtime are shared.
        @MainActor public final class WatchPhoneRelay<Codec: RelayWatchCodec, Preview: Sendable> {
            public var onCommand: (@MainActor @Sendable (RelayWatchAction) -> Codec.Result)? {
                get { owner.onCommand }
                set { owner.onCommand = newValue }
            }
            public var onAdmittedCommand:
                (@MainActor @Sendable (RelayWatchAction, RelayWatchCommandAdmission) -> Codec.Result)?
            {
                get { owner.onAdmittedCommand }
                set { owner.onAdmittedCommand = newValue }
            }
            public var onReachabilityChanged: (@MainActor @Sendable () -> Void)? {
                get { owner.onReachabilityChanged }
                set { owner.onReachabilityChanged = newValue }
            }
            private let owner: RelayWatchPhoneOwner<Codec, Preview>
            private let port: WatchSDKPort
            public init(
                codec: Codec, policy: RelayWatchPhonePolicy,
                encode: @escaping @Sendable (Preview, RelayPreviewProfile) async -> Codec.Frame?
            ) {
                let port = WatchSDKPort()
                self.port = port
                owner = RelayWatchPhoneOwner(
                    codec: codec, policy: policy, now: { ProcessInfo.processInfo.systemUptime },
                    send: { port.send($0, reply: $1, failure: $2) },
                    updateContext: { port.updateContext($0) }, encode: encode)
                owner.onSourceRetired = { [weak port] in port?.publish($0) }
            }
            public var isReady: Bool { owner.isReady }
            public var hasCompanion: Bool { port.hasCompanion }
            public func admits(_ admission: RelayWatchCommandAdmission) -> Bool {
                owner.admits(admission)
            }
            public func activate() {
                owner.acceptLink(activated: port.activated, reachable: port.reachable)
                let owner = self.owner
                port.arm(
                    WatchSDKDelegate(
                        window: owner.source, immediateReply: false,
                        receive: { [weak owner] data, window, reply in
                            Task { @MainActor in
                                let response = owner?.receiveCommand(data, source: window) ?? Data()
                                reply?(response)
                            }
                        },
                        link: { [weak owner] activated, reachable, window in
                            Task { @MainActor in
                                guard let owner, owner.source == window else { return }
                                owner.acceptLink(activated: activated, reachable: reachable)
                            }
                        }, context: { _, _ in }))
            }
            public func ingestState(_ state: Codec.State) { owner.ingestState(state) }
            public func ingestPreview(_ preview: Preview) { owner.ingestPreview(preview) }
            public func retireSource() { owner.retireSource() }
            public func close() {
                owner.close()
                port.close()
            }
        }

        @MainActor private final class WatchSDKTimer: RelayWatchScheduled {
            var task: Task<Void, Never>?
            func cancel() {
                task?.cancel()
                task = nil
            }
        }
        @MainActor private final class WatchSDKScheduler: RelayWatchScheduler {
            func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void)
                -> any RelayWatchScheduled
            {
                let timer = WatchSDKTimer()
                timer.task = Task {
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    guard !Task.isCancelled else { return }
                    action()
                }
                return timer
            }
        }

        /// Observable SDK projection. The confined portable owner admits messages/replies before this
        /// leaf decodes native image bytes; the UI receives the original codec's typed state and timecode.
        @MainActor @Observable public final class WatchReceiver<Codec: RelayWatchCodec> {
            public private(set) var presentationRevision: UInt64 = 0
            public private(set) var feedImage: UIImage?
            public private(set) var frameTimecode: Codec.Timecode?
            public private(set) var state: Codec.State?
            public private(set) var isReachable = false
            public private(set) var isSendingCommand = false
            public private(set) var commandMessage: String?
            @ObservationIgnored private let owner: RelayWatchReceiverOwner<Codec>
            @ObservationIgnored private let port: WatchSDKPort
            @ObservationIgnored private let codec: Codec
            @ObservationIgnored private let acceptsContext: Bool
            @ObservationIgnored private var lastImageBytes: Data?
            public init(codec: Codec, acceptsContext: Bool, simulatorImage: UIImage? = nil) {
                self.codec = codec
                self.acceptsContext = acceptsContext
                let port = WatchSDKPort()
                self.port = port
                owner = RelayWatchReceiverOwner(
                    codec: codec, scheduler: WatchSDKScheduler(),
                    send: { port.send($0, reply: $1, failure: $2) })
                owner.onSourceRetired = { [weak port] in port?.publish($0) }
                owner.onChange = { [weak self] in self?.project() }
                #if targetEnvironment(simulator)
                    feedImage = simulatorImage
                #endif
            }
            public func activate() {
                owner.activate(reachable: port.reachable)
                let owner = self.owner
                let acceptsContext = self.acceptsContext
                port.arm(
                    WatchSDKDelegate(
                        window: owner.source, immediateReply: true,
                        receive: { [weak owner] data, window, _ in
                            Task { @MainActor in owner?.receive(data, source: window) }
                        },
                        link: { [weak owner] _, reachable, window in
                            Task { @MainActor in
                                owner?.acceptReachability(reachable, source: window)
                            }
                        },
                        context: { [weak owner] data, window in
                            guard acceptsContext else { return }
                            Task { @MainActor in owner?.receive(data, source: window) }
                        }))
                if acceptsContext,
                    let data = port.session?.receivedApplicationContext[WatchRelayContext.stateKey]
                        as? Data
                {
                    owner.receive(data, source: owner.source)
                }
            }
            public func resume() {
                activate()
                owner.send(.resume)
            }
            public func sendCapture() { owner.send(.capture) }
            public func sendToggleRecord() { owner.send(.toggleRecord) }
            public func close() {
                owner.close()
                port.close()
            }
            private func project() {
                presentationRevision = owner.presentationRevision
                state = owner.state
                isReachable = owner.isReachable
                isSendingCommand = owner.isSendingCommand
                commandMessage = owner.commandMessage
                if let frame = owner.frame {
                    frameTimecode = codec.timecode(frame)
                    let data = codec.imageBytes(frame)
                    if data != lastImageBytes, let image = UIImage(data: data) {
                        lastImageBytes = data
                        feedImage = image
                    }
                } else {
                    frameTimecode = nil
                }
            }
        }
    #endif
#endif
