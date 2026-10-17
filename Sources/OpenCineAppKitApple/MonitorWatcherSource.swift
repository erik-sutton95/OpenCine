#if os(iOS)
import Foundation
import Network
import Observation
import MonitorPresentation
import OpenCineRelayApple
import OpenCineRelay
import OpenCineApple

private struct WatcherJoinDestination {
    let endpoint: NWEndpoint
    let hostName: String
    let passcode: String
    let watcherID: String
    let deviceName: String
}

/// Complete native watcher source lifecycle over one existing relay connection and one decoder.
/// Camera interpretation and preparation are supplied once by the integration composition.
@MainActor @Observable public final class MonitorWatcherSource<Decoder: MonitorLiveVideoRuntime> {
    @ObservationIgnored private let versionMismatchReason: String
    @ObservationIgnored private let journal: @Sendable (String) -> Void
    @ObservationIgnored public var preparePicture: (@MainActor () -> Void)?
    @ObservationIgnored private let commandWire: (@MainActor (Data) -> Void)?
    /// The relay's poll and recovery clock; `nil` keeps the relay client's own (uptime) clock.
    @ObservationIgnored private let clock: MonitorHostClock?
    @ObservationIgnored private var client: RelayAppleClient<SharedMonitorRelayCodec>?
    @ObservationIgnored private var nativeEpisode = UUID()
    @ObservationIgnored private var destination: WatcherJoinDestination?
    @ObservationIgnored public var resolveEndpoint: (@MainActor (String) -> NWEndpoint?)?
    @ObservationIgnored public var onReconnect: (@MainActor () -> Void)?
    @ObservationIgnored private var reportedStatus: RelayWatcherPhase = .idle
    public var status: RelayWatcherPhase {
        get { access(keyPath: \.status); return reportedStatus }
        set { guard reportedStatus != newValue else { return }; reportedStatus = newValue; notify(.status) }
    }
    @ObservationIgnored private var reportedState: WatcherRelayState = .init()
    public var state: WatcherRelayState {
        get { access(keyPath: \.state); return reportedState }
        set { guard reportedState != newValue else { return }; reportedState = newValue; notify(.state) }
    }
    @ObservationIgnored private var reportedToken: WatcherRelayControlToken = .init(holderName: "Host", holderIsRecipient: false)
    public var token: WatcherRelayControlToken {
        get { access(keyPath: \.token); return reportedToken }
        set { guard reportedToken != newValue else { return }; reportedToken = newValue; notify(.token) }
    }
    @ObservationIgnored private var reportedHostTitle: String = ""
    public var hostTitle: String {
        get { access(keyPath: \.hostTitle); return reportedHostTitle }
        set { guard reportedHostTitle != newValue else { return }; reportedHostTitle = newValue; notify(.hostTitle) }
    }
    @ObservationIgnored private var reportedActionRevision: UInt64 = 0
    public private(set) var actionRevision: UInt64 {
        get { access(keyPath: \.actionRevision); return reportedActionRevision }
        set { guard reportedActionRevision != newValue else { return }; reportedActionRevision = newValue; notify(.actionRevision) }
    }
    @ObservationIgnored private var reportedReceivedFPS: Int = 0
    public var receivedFPS: Int {
        get { access(keyPath: \.receivedFPS); return reportedReceivedFPS }
        set { guard reportedReceivedFPS != newValue else { return }; reportedReceivedFPS = newValue; notify(.receivedFPS) }
    }
    @ObservationIgnored private var reportedWaitingForPicture: Bool = false
    public var waitingForPicture: Bool {
        get { access(keyPath: \.waitingForPicture); return reportedWaitingForPicture }
        set { guard reportedWaitingForPicture != newValue else { return }; reportedWaitingForPicture = newValue; notify(.waitingForPicture) }
    }
    @ObservationIgnored private var reportedControlRequested: Bool = false
    public var controlRequested: Bool {
        get { access(keyPath: \.controlRequested); return reportedControlRequested }
        set { guard reportedControlRequested != newValue else { return }; reportedControlRequested = newValue; notify(.controlRequested) }
    }
    private enum Field: Equatable {
        case status, state, token, hostTitle, actionRevision, receivedFPS, waitingForPicture, controlRequested
    }
    @ObservationIgnored private var notifying = false
    @ObservationIgnored private var pendingNotifications: [Field] = []

    // Commit storage immediately; notify nested changes after the outgoing callback unregisters.
    private func notify(_ field: Field) {
        if !pendingNotifications.contains(field) { pendingNotifications.append(field) }
        guard !notifying else { return }
        notifying = true
        defer { notifying = false }
        while !pendingNotifications.isEmpty {
            switch pendingNotifications.removeFirst() {
            case .status: withMutation(keyPath: \.status) {}
            case .state: withMutation(keyPath: \.state) {}
            case .token: withMutation(keyPath: \.token) {}
            case .hostTitle: withMutation(keyPath: \.hostTitle) {}
            case .actionRevision: withMutation(keyPath: \.actionRevision) {}
            case .receivedFPS: withMutation(keyPath: \.receivedFPS) {}
            case .waitingForPicture: withMutation(keyPath: \.waitingForPicture) {}
            case .controlRequested: withMutation(keyPath: \.controlRequested) {}
            }
        }
    }

    public let decoder: Decoder
    public let samples: LiveFrameSampleBus
    public var canControl: Bool { status == .live && token.holderIsRecipient }
    public var tapSource: MonitorWatcherTapSource {
        .init(source: String(describing: ObjectIdentifier(self)), revision: actionRevision, canControl: canControl)
    }
    public init(decoder: Decoder, samples: LiveFrameSampleBus, versionMismatchReason: String,
        journal: @escaping @Sendable (String) -> Void = { _ in },
        commandWire: (@MainActor (Data) -> Void)? = nil, clock: MonitorHostClock? = nil) {
        self.decoder = decoder; self.samples = samples
        self.versionMismatchReason = versionMismatchReason; self.journal = journal; self.commandWire = commandWire
        self.clock = clock
    }

    public func join(endpoint: NWEndpoint, hostName: String, passcode: String, watcherID: String, deviceName: String) {
        let retired = retireNativeAdapter()
        guard nativeEpisode == retired, client == nil else { return }
        let episode = UUID(); nativeEpisode = episode
        actionRevision &+= 1
        guard nativeEpisode == episode else { return }
        destination = .init(endpoint: endpoint, hostName: hostName, passcode: passcode, watcherID: watcherID, deviceName: deviceName)
        hostTitle = hostName
        guard nativeEpisode == episode else { return }
        state = .init()
        guard nativeEpisode == episode else { return }
        token = .init(holderName: "Host", holderIsRecipient: false)
        guard nativeEpisode == episode else { return }
        receivedFPS = 0
        guard nativeEpisode == episode else { return }
        waitingForPicture = false
        guard nativeEpisode == episode else { return }
        controlRequested = false
        guard nativeEpisode == episode else { return }
        status = .connecting
        guard nativeEpisode == episode, client == nil else { return }
        decoder.sampleBus = samples
        guard nativeEpisode == episode, client == nil else { return }
        preparePicture?()
        guard nativeEpisode == episode, client == nil else { return }
        let watcher = RelayAppleWatcherConfiguration<SharedMonitorRelayCodec.FrameMetadata,
            SharedMonitorRelayCodec.ControlToken, SharedMonitorRelayCodec.JoinDenied>(deviceName: deviceName,
                passcode: passcode.isEmpty ? nil : passcode, encodedAt: { $0.encodedAt },
                holderIsRecipient: { $0.holderIsRecipient },
                refusal: { .init(reason: $0.reason, passcodeRequired: $0.passcodeRequired) })
        let transport = if let clock {
            RelayAppleClient(codec: SharedMonitorRelayCodec(), watcherID: watcherID,
                versionMismatchReason: versionMismatchReason, journal: journal,
                sleep: { seconds in try? await clock.sleep(.seconds(seconds)) },
                now: { clock.now().sinceReference / .seconds(1) }, watcher: watcher)
        } else {
            RelayAppleClient(codec: SharedMonitorRelayCodec(), watcherID: watcherID,
                versionMismatchReason: versionMismatchReason, journal: journal, watcher: watcher)
        }
        client = transport
        transport.onWatcherChanged = { [weak self, weak transport] next in
            guard let self, let transport, self.client === transport else { return }
            if self.status != next.phase { self.actionRevision &+= 1 }
            guard self.client === transport else { return }
            if !transport.watcherCanControl {
                self.token = .init(holderName: self.token.holderName, holderIsRecipient: false)
            }
            guard self.client === transport else { return }
            self.status = next.phase
            guard self.client === transport else { return }
            self.receivedFPS = next.receivedFPS
            guard self.client === transport else { return }
            self.waitingForPicture = next.waitingForPicture
            guard self.client === transport else { return }
            self.controlRequested = next.controlRequested
        }
        transport.onStateChanged = { [weak self, weak transport] next in
            guard let self, let transport, self.client === transport else { return }
            if case .connected(let host, let camera) = next {
                if let camera, !camera.isEmpty { self.hostTitle = "\(host) · \(camera)" }
                else { self.hostTitle = host }
            }
        }
        transport.onRelayState = { [weak self, weak transport] next in
            guard let self, let transport, self.client === transport else { return }
            if self.state != next { self.state = next }
        }
        transport.onControlToken = { [weak self, weak transport] next in
            guard let self, let transport, self.client === transport else { return }
            if self.token != next {
                self.actionRevision &+= 1
                guard self.client === transport else { return }
                self.token = next
            }
        }
        transport.onSourceBegan = { [weak self, weak transport] source, recovering in
            guard let self, let transport, self.client === transport else { return }
            self.actionRevision &+= 1
            guard self.client === transport, transport.sourceToken == source else { return }
            if recovering { self.decoder.flushForRecovery() }
            guard self.client === transport, transport.sourceToken == source,
                let native = self.decoder.sourceToken else { return }
            let epoch = self.samples.inspectorSourceEpoch
            self.decoder.onPresentedFrame = { [weak self, weak transport] in
                guard let self, let transport, self.client === transport, transport.sourceToken == source,
                    self.decoder.sourceToken == native, self.samples.inspectorSourceEpoch == epoch,
                    let presented = self.decoder.monitorPresentedAt else { return }
                transport.notePresentedPicture(source: source, presentation: presented.timeIntervalSinceReferenceDate)
            }
        }
        transport.onFrame = { [weak self, weak transport] metadata, bytes in
            guard let self, let transport, self.client === transport else { return }
            let source = transport.sourceToken, native = self.decoder.sourceToken
            let epoch = self.samples.inspectorSourceEpoch
            self.decoder.poseViewFlip = metadata.extraMirrored
            guard self.client === transport, transport.sourceToken == source,
                self.decoder.sourceToken == native, self.samples.inspectorSourceEpoch == epoch else { return }
            self.decoder.decode(accessUnit: Array(bytes), source: native)
        }
        transport.resolveWatcherEndpoint = { [weak self, weak transport] old in
            guard let self, let transport, self.client === transport else { return nil }
            guard let destination = self.destination else { return nil }
            return self.resolveEndpoint?(destination.hostName) ?? RelayAppleNetwork.rediscoveryEndpoint(old)
        }
        transport.onReconnect = { [weak self, weak transport] in
            guard let self, let transport, self.client === transport else { return }
            self.onReconnect?()
        }
        transport.connect(to: endpoint)
    }
    public func retryPasscode(_ code: String) {
        guard let destination else { return }
        join(endpoint: destination.endpoint, hostName: destination.hostName, passcode: code,
            watcherID: destination.watcherID, deviceName: destination.deviceName)
    }
    public func leave() { _ = retireNativeAdapter() }
    @discardableResult private func retireNativeAdapter() -> UUID {
        let episode = UUID(); nativeEpisode = episode
        let retired = client; client = nil
        retired?.stop()
        actionRevision &+= 1
        guard nativeEpisode == episode, client == nil else { return episode }
        controlRequested = false
        guard nativeEpisode == episode, client == nil else { return episode }
        waitingForPicture = false
        guard nativeEpisode == episode, client == nil else { return episode }
        status = .idle
        guard nativeEpisode == episode, client == nil else { return episode }
        decoder.onPresentedFrame = nil; decoder.reset()
        return episode
    }
    public func requestControl() {
        guard status == .live, state.allowsControlRequests, !controlRequested else { return }
        client?.requestControl()
    }
    public func releaseControl() { guard canControl else { return }; client?.releaseControl() }
    public func toggleRecording() { sendCommand(.toggleRecording) }
    public func setISO(_ index: Int) { sendCommand(.setISO(index)) }
    public func setShutterDenominator(_ denominator: Int) { sendCommand(.setShutterDenom(denominator)) }
    public func setZoom(_ hundredths: Int) { sendCommand(.setZoom(hundredths)) }

    /// Map the admitted displayed tap and submit its relay command in the native source owner.
    /// A replaced source cannot publish the focus mark after an entered wire callback.
    public func sendTapFocus(x: Double, y: Double, width: Double, height: Double,
        mirrored: Bool, flippedVertically: Bool, captured: MonitorWatcherTapSource
    ) -> MonitorWatcherFocus? {
        guard captured.admits(tapSource),
            let point = WatcherFocusPoint.map(x: x, y: y, width: width, height: height,
                mirrored: mirrored, flippedVertically: flippedVertically),
            sendCommand(.tapFocus(cameraX: point.x, cameraY: point.y,
                coordinateWidth: 1000, coordinateHeight: 1000), captured: captured)
        else { return nil }
        return .init(source: captured, x: Double(point.x) / 1000, y: Double(point.y) / 1000)
    }

    public func sendCommand(_ command: WatcherRelayCommand) { _ = sendCommand(command, captured: tapSource) }
    @discardableResult public func sendCommand(_ command: WatcherRelayCommand, captured: MonitorWatcherTapSource) -> Bool {
        guard captured.admits(tapSource) else { return false }
        if let commandWire {
            guard let payload = try? JSONEncoder().encode(command), captured.admits(tapSource) else { return false }
            commandWire(WatcherRelayFraming.encode(kind: .command, payload: payload))
        } else {
            guard let client, client.watcherCanControl, captured.admits(tapSource) else { return false }
            client.send(command: command)
        }
        return captured.admits(tapSource)
    }
}

/// Where a watcher's join to a shared feed stands, for the browse screen.
public enum WatcherJoinStatus: Equatable, Sendable {
    case idle
    case connecting
    case reconnecting(attempt: Int, maximum: Int)
    case needsPasscode
    case live
    case failed(String)
}

/// One shared feed found on this network.
public struct WatcherFeedRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let cameraName: String?

    public init(id: String, name: String, cameraName: String?) {
        self.id = id
        self.name = name
        self.cameraName = cameraName
    }
}

/// The watcher side of the shared relay for an app that watches another phone's feed: browse,
/// join with the remembered passcode, retry a passcode, leave, and the navigation between the
/// browse screen and the watcher monitor. Its members satisfy the camera controls'
/// `WatcherBrowseHost`. The app supplies its relay objects, Keychain service and the one chrome
/// step that differs (closing its own covers).
@MainActor
public protocol WatcherRelayViewer: AnyObject {
    associatedtype WatcherDecoder: MonitorLiveVideoRuntime
    var relayClient: MonitorWatcherSource<WatcherDecoder> { get }
    var relayBrowser: WatcherRelayBrowser { get }
    /// This app's relay secrets.
    var relayKeychain: WatcherRelayKeychain { get }
    var isWatchingFeed: Bool { get set }
    var showsWatcherBrowse: Bool { get set }
    /// A phone with a live camera of its own does not browse for other feeds.
    var isLive: Bool { get }
    /// This phone's name, shown to the sharing phone.
    var watcherDeviceName: String { get }
    /// Close the app's own covers so the watcher monitor shows once a join goes live.
    func dismissCoversForWatching()
}

extension WatcherRelayViewer {
    public var watcherJoinStatus: WatcherJoinStatus {
        switch relayClient.status {
        case .idle: .idle
        case .connecting: .connecting
        case .reconnecting(let attempt):
            .reconnecting(attempt: attempt, maximum: WatcherRelayRecovery.maximumRetries)
        case .needsPasscode: .needsPasscode
        case .live: .live
        case .failed(let message): .failed(message)
        }
    }

    public var watcherFeeds: [WatcherFeedRow] {
        relayBrowser.hosts.map {
            WatcherFeedRow(id: $0.id, name: $0.name, cameraName: $0.cameraName)
        }
    }

    public var watcherBrowseError: String? { relayBrowser.browseError }

    /// Once accepted, transport failure belongs on the watcher screen until explicit Leave.
    public var showsWatcherMonitor: Bool { isWatchingFeed }

    public func joinWatcherFeed(id: String) {
        guard let feed = relayBrowser.hosts.first(where: { $0.id == id }) else { return }
        joinWatcher(feed)
    }

    public func openWatcherBrowse() {
        showsWatcherBrowse = true
        relayClient.resolveEndpoint = { [weak self] name in
            self?.relayBrowser.hosts.first { $0.name == name }?.endpoint
        }
        relayClient.onReconnect = { [weak self] in self?.startWatcherBrowse() }
        startWatcherBrowse()
    }

    public func startWatcherBrowse() {
        guard !isLive else { return }
        relayBrowser.start()
    }

    public func joinWatcher(_ host: WatcherRelayDiscovery) {
        relayClient.join(
            endpoint: host.endpoint,
            hostName: host.name,
            passcode: relayKeychain.rememberedPasscode(forHost: host.name),
            watcherID: relayKeychain.installID,
            deviceName: watcherDeviceName)
    }

    /// A failed save keeps the passcode for this join; the next join asks again. The answer is
    /// trimmed by the shared rule and an empty one is ignored.
    public func retryWatcherPasscode(_ code: String) {
        guard let code = MonitorWatcherPasscodeRule.answer(code) else { return }
        relayKeychain.storeRememberedPasscode(code, forHost: relayClient.hostTitle)
        relayClient.retryPasscode(code)
    }

    public func stopWatching() {
        relayClient.leave()
        isWatchingFeed = false
        showsWatcherBrowse = false
        relayBrowser.stop()
    }

    /// A passcode demand while watching returns to browse; a live join leaves browse for the
    /// watcher monitor.
    public func noteWatcherStatusChanged(_ status: RelayWatcherPhase) {
        if status == .needsPasscode, isWatchingFeed {
            isWatchingFeed = false
            showsWatcherBrowse = true
            startWatcherBrowse()
        }
        if status == .live, showsWatcherBrowse {
            isWatchingFeed = true
            showsWatcherBrowse = false
            dismissCoversForWatching()
        }
    }
}
#endif
