#if canImport(VideoToolbox) && canImport(Network)
import AVFoundation
import Foundation
import MonitorPresentation
import Observation
import OpenCineApple
import OpenCineCore
import OpenCineStreaming
import OpenCineStreamingApple

/// What an app gives live streaming: host values only, never a camera or a brand.
public struct LiveStreamHost {
    /// The keychain service for stream keys and entered servers, such as `<bundle id>.live-stream`.
    public var keychainService: String
    /// Where the selected service and the monitor switch are remembered.
    public var defaults: UserDefaults
    /// How the device reaches the camera now, from the app's existing connection mode; `nil`
    /// without a camera. Decides whether going live is allowed.
    public var route: @MainActor () -> StreamConnectionRoute?
    /// What the selected camera's feed delivers now; `nil` before a picture arrives.
    public var source: @MainActor () -> StreamSourceFormat?
    /// Sets (or, with `nil`, removes) the clean picture tap on the app's live picture runtime.
    public var attachPicture: @MainActor (MonitorCleanPictureTap?) -> Void
    /// The app's own microphone permission path, asked once the operator confirms Go live; `true`
    /// when the stream may use the microphone. Shared code never raises the system prompt itself.
    /// `LiveStreamHost.systemMicrophoneAccess` is the plain system request for an app with no
    /// gate of its own.
    public var microphoneAccess: @MainActor () async -> Bool

    public init(
        keychainService: String, defaults: UserDefaults = .standard,
        route: @escaping @MainActor () -> StreamConnectionRoute?,
        source: @escaping @MainActor () -> StreamSourceFormat?,
        attachPicture: @escaping @MainActor (MonitorCleanPictureTap?) -> Void,
        microphoneAccess: @escaping @MainActor () async -> Bool
    ) {
        self.keychainService = keychainService
        self.defaults = defaults
        self.route = route
        self.source = source
        self.attachPicture = attachPicture
        self.microphoneAccess = microphoneAccess
    }

    /// The system microphone request (asked once; later calls return the saved answer).
    @MainActor public static func systemMicrophoneAccess() async -> Bool {
        #if os(iOS)
            await StreamMicrophone.requestPermission()
        #else
            false
        #endif
    }
}

/// The key store as the coordinator uses it (`StreamKeyStore` in production).
protocol LiveStreamKeyStoring: Sendable {
    func key(for presetID: String) -> StreamKeyStore.Lookup
    func server(for presetID: String) -> StreamKeyStore.Lookup
    func save(key: String, server: String?, for presetID: String) -> Bool
    func remove(for presetID: String) -> Bool
}

extension StreamKeyStore: LiveStreamKeyStoring {}

/// One running stream as the coordinator drives it (`StreamPublisher` in production).
protocol LiveStreamPublishing: AnyObject, Sendable {
    func onStatus(_ handler: @escaping @Sendable (StreamRun.Status) -> Void)
    func start()
    func stop()
    func submitVideo(_ buffer: CVPixelBuffer)
    func submitAudio(_ buffer: AVAudioPCMBuffer)
}

extension StreamPublisher: LiveStreamPublishing {}

/// The stream's sound (the device microphone in production).
@MainActor protocol LiveStreamAudioCapture: AnyObject {
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    func stop()
}

/// Live streaming for one app: the settings card's values and actions, going live and stopping,
/// the status the monitor shows, and the lifecycle rules. Streaming is a passenger: it reads the
/// host's route and source and attaches a picture tap, and never sends a camera command or touches
/// the monitor, so a stream failure stays inside the stream.
@available(macOS 14.0, *)
@MainActor @Observable public final class LiveStreamCoordinator {
    private struct Running {
        let publisher: any LiveStreamPublishing
        let format: StreamOutputFormat
        let encrypted: Bool
        let relay: StatusRelay
    }

    @ObservationIgnored private let host: LiveStreamHost
    @ObservationIgnored private let keys: any LiveStreamKeyStoring
    @ObservationIgnored private let audio: (any LiveStreamAudioCapture)?
    @ObservationIgnored private let makePublisher:
        (StreamDestination, StreamOutputFormat, StreamPictureFitter.Mode) -> any LiveStreamPublishing
    @ObservationIgnored private let now: @Sendable () -> MonotonicInstant

    private var selectedID: String
    private var serverDraft = ""
    private var keyState: LiveStreamKeyState = .absent
    private var problem: LiveStreamProblem?
    private var showOnMonitor: Bool
    private var phase: LiveStreamPhase = .idle
    private var status: LiveStreamStatusState?
    private var end: LiveStreamEnd?
    private var hot = false
    private var lowBattery = false
    private var running: Running?
    @ObservationIgnored private var starting = false
    /// Monitor overlays on screen now; with none, a running stream shows the app-level pill.
    private(set) var monitorControlsOnScreen = 0

    private static let presets = StreamServicePreset.all + [.custom]
    private static let serviceKey = "opencine.livestream.service"
    private static let monitorKey = "opencine.livestream.showOnMonitor"
    /// The output before a camera states its feed: the spec's wireless default.
    private static let fallbackSource = StreamSourceFormat(width: 1280, height: 720, frameRate: Rational(30, 1))

    public convenience init(host: LiveStreamHost) {
        #if os(iOS)
            let audio: (any LiveStreamAudioCapture)? = MicrophoneCapture()
        #else
            let audio: (any LiveStreamAudioCapture)? = nil
        #endif
        self.init(
            host: host, keys: StreamKeyStore(service: host.keychainService), audio: audio,
            makePublisher: { StreamPublisher(destination: $0, format: $1, fitting: $2) },
            now: { MonotonicInstant.now() })
    }

    init(
        host: LiveStreamHost, keys: any LiveStreamKeyStoring, audio: (any LiveStreamAudioCapture)?,
        makePublisher: @escaping (StreamDestination, StreamOutputFormat, StreamPictureFitter.Mode) -> any LiveStreamPublishing,
        now: @escaping @Sendable () -> MonotonicInstant
    ) {
        self.host = host
        self.keys = keys
        self.audio = audio
        self.makePublisher = makePublisher
        self.now = now
        let saved = host.defaults.string(forKey: Self.serviceKey)
        selectedID = Self.presets.contains { $0.id == saved } ? saved ?? "" : Self.presets[0].id
        showOnMonitor = host.defaults.object(forKey: Self.monitorKey) as? Bool ?? true
        reloadKey()
    }

    // MARK: Values

    private var preset: StreamServicePreset { Self.presets.first { $0.id == selectedID } ?? Self.presets[0] }

    public var isRunning: Bool { phase.isRunning }

    private var eligibility: LiveStreamEligibility {
        switch host.route() {
        case .cameraWiFi: .cameraWiFi
        case nil: .noCamera
        case .usbCable, .captureCard, .sharedWiFi, .deviceHotspot: .allowed
        }
    }

    private var format: StreamOutputFormat? {
        if let running { return running.format }
        guard let source = host.source() else { return nil }
        return StreamOutputFormat.resolve(selected: source, connected: [], preset: preset)
    }

    private var quality: LiveStreamQuality? {
        format.map {
            LiveStreamQuality(width: $0.width, height: $0.height, framesPerSecond: $0.frameRate.doubleValue,
                videoBitrateBps: $0.videoBitrateBps)
        }
    }

    /// Whether the saved (or entered) server is encrypted; a fixed preset server always is.
    private var encrypted: Bool {
        if let running { return running.encrypted }
        return !(preset.allowsPlainRTMP
            && serverDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("rtmp://"))
    }

    public var settingsState: LiveStreamSettingsState {
        LiveStreamSettingsState(
            services: Self.presets.map {
                LiveStreamServiceOption(id: $0.id, name: $0.displayName, keyHint: $0.keyHint,
                    needsServer: $0.requiresServerEntry, acceptsPlainServer: $0.allowsPlainRTMP,
                    vertical: $0.aspect == .portrait9x16)
            },
            selectedID: selectedID, server: serverDraft, key: keyState, quality: quality,
            sourceHeight: host.source().map { min($0.width, $0.height) }, eligibility: eligibility,
            showOnMonitor: showOnMonitor, phase: phase, problem: problem)
    }

    /// What the monitor shows, or `nil` when the Go live control is hidden (no saved key, or the
    /// operator turned it off) and nothing is running or to report.
    public var monitorState: LiveStreamMonitorState? {
        guard phase.isRunning || end != nil || (showOnMonitor && keyState == .saved) else { return nil }
        return LiveStreamMonitorState(
            control: LiveStreamControlState(phase: phase, eligibility: eligibility, serviceName: preset.displayName,
                elapsedSeconds: status?.elapsedSeconds ?? 0),
            serviceName: preset.displayName, quality: quality, encrypted: encrypted, status: status, end: end,
            warning: phase.isRunning ? (hot ? .hot : lowBattery ? .lowBattery : nil) : nil)
    }

    /// The app-level pill: a running stream with no monitor showing its control, so the operator
    /// can always see and stop it.
    public var pillState: LiveStreamPillState? {
        guard phase.isRunning, monitorControlsOnScreen == 0 else { return nil }
        return LiveStreamPillState(phase: phase, serviceName: preset.displayName,
            elapsedSeconds: status?.elapsedSeconds ?? 0)
    }

    /// A monitor overlay came on screen (`LiveStreamMonitorOverlay` reports this itself).
    public func monitorControlsAppeared() { monitorControlsOnScreen += 1 }

    public func monitorControlsDisappeared() { monitorControlsOnScreen = max(0, monitorControlsOnScreen - 1) }

    // MARK: Settings actions

    public func selectService(_ id: String) {
        guard !phase.isRunning, Self.presets.contains(where: { $0.id == id }) else { return }
        selectedID = id
        host.defaults.set(id, forKey: Self.serviceKey)
        problem = nil
        reloadKey()
    }

    public func setServer(_ text: String) {
        guard !phase.isRunning, keyState != .saved else { return }
        serverDraft = text
        problem = nil
    }

    /// Validates the pasted key with the entered server and the service's scheme rule, then stores
    /// both. A refusal is shown as a problem and nothing is stored.
    public func saveKey(_ pasted: String) {
        guard !phase.isRunning else { return }
        let server = preset.requiresServerEntry ? serverDraft.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        do {
            _ = try StreamDestination(preset: preset, enteredServerURL: server, streamKey: pasted)
        } catch let error as StreamDestinationError {
            problem = Self.problem(error, plainAllowed: preset.allowsPlainRTMP)
            return
        } catch {
            problem = .invalidServer
            return
        }
        let key = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if keys.save(key: key, server: server, for: preset.id) {
            problem = nil
            keyState = .saved
            serverDraft = server ?? ""
        } else {
            reloadKey()
        }
    }

    public func removeKey() {
        guard !phase.isRunning else { return }
        _ = keys.remove(for: preset.id)
        reloadKey()
    }

    public func setShowOnMonitor(_ value: Bool) {
        showOnMonitor = value
        host.defaults.set(value, forKey: Self.monitorKey)
    }

    // MARK: Going live

    /// Starts a stream after the operator's one confirmation (or the background restart).
    public func start() { Task { await begin() } }

    public func restart() { start() }

    public func stop() {
        guard running != nil else { return }
        finish(.stopped, stopPublisher: true)
    }

    public func dismissNotice() {
        end = nil
        if case .ended = phase { phase = .idle }
    }

    /// The app left the screen: streaming is foreground only, so the stream ends now and a notice
    /// offers one tap restart on return.
    public func sceneDidEnterBackground() {
        guard running != nil else { return }
        finish(.background, stopPublisher: true)
    }

    /// Warn on heat or a low battery while live; never stop for them.
    public func updateDeviceConditions(hot: Bool, lowBattery: Bool) {
        self.hot = hot
        self.lowBattery = lowBattery
    }

    func begin() async {
        guard !phase.isRunning, !starting else { return }
        starting = true
        defer { starting = false }
        end = nil
        if case .ended = phase { phase = .idle }
        guard eligibility.allowsGoLive else { return }
        reloadKey()
        guard case .stored(let key) = keys.key(for: preset.id) else { return }
        let server = preset.requiresServerEntry ? keys.server(for: preset.id).value : nil
        let destination: StreamDestination
        do {
            destination = try StreamDestination(preset: preset, enteredServerURL: server, streamKey: key)
        } catch let error as StreamDestinationError {
            problem = Self.problem(error, plainAllowed: preset.allowsPlainRTMP)
            return
        } catch {
            return
        }
        let format = StreamOutputFormat.resolve(
            selected: host.source() ?? Self.fallbackSource, connected: [], preset: preset)
        if audio != nil, await !host.microphoneAccess() {
            phase = .ended(.microphoneDenied)
            end = .microphoneDenied
            return
        }
        guard !phase.isRunning, eligibility.allowsGoLive else { return }

        let publisher = makePublisher(destination, format, preset.aspect == .portrait9x16 ? .centerCrop : .fit)
        let relay = StatusRelay(now: now)
        relay.deliver = { [weak self] status, instant in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.relayed(status, at: instant, from: relay) }
            }
        }
        publisher.onStatus { relay.offer($0) }
        running = Running(publisher: publisher, format: format, encrypted: destination.isEncrypted, relay: relay)
        phase = .connecting
        status = LiveStreamStatusState(phase: .connecting, elapsedSeconds: 0, sentBitrateBps: 0, droppedGroups: 0,
            health: .offline)
        host.attachPicture(MonitorCleanPictureTap { publisher.submitVideo($0.pixelBuffer) })
        try? audio?.start { publisher.submitAudio($0) }
        publisher.start()
    }

    private func relayed(_ status: StreamRun.Status, at instant: MonotonicInstant, from relay: StatusRelay) {
        guard running?.relay === relay else { return }
        receive(status, at: instant)
    }

    /// One status from the running stream.
    func receive(_ run: StreamRun.Status, at instant: MonotonicInstant) {
        guard running != nil else { return }
        switch run.phase {
        case .connecting: phase = .connecting
        case .live: phase = .live
        case .reconnecting(let attempt):
            // A first connection that fails ends at once; only a stream that went live retries.
            guard run.liveSince != nil else { return finish(.unreachable, stopPublisher: true) }
            phase = .reconnecting(attempt: attempt)
        case .ended(.stopped): return finish(.stopped, stopPublisher: false)
        case .ended(.refused(let reason)): return finish(.refused(reason: reason), stopPublisher: false)
        case .ended(.gaveUp): return finish(.gaveUp, stopPublisher: false)
        }
        let elapsed = run.liveSince.map { Int((instant - $0).components.seconds) } ?? 0
        let health: LiveStreamHealth = switch run.health {
        case .good: .good
        case .congested: .congested
        case .offline: .offline
        }
        status = LiveStreamStatusState(phase: phase, elapsedSeconds: max(0, elapsed),
            sentBitrateBps: run.sentBitrateBps, droppedGroups: run.droppedVideoGroups, health: health)
    }

    private func finish(_ reason: LiveStreamEnd, stopPublisher: Bool) {
        guard let running else { return }
        running.relay.cancel()
        if stopPublisher { running.publisher.stop() }
        host.attachPicture(nil)
        audio?.stop()
        self.running = nil
        status = nil
        phase = reason == .stopped ? .idle : .ended(reason)
        end = reason == .stopped ? nil : reason
    }

    private func reloadKey() {
        switch keys.key(for: preset.id) {
        case .stored: keyState = .saved
        case .absent: keyState = .absent
        case .unavailable: keyState = .unavailable
        }
        serverDraft = preset.requiresServerEntry ? keys.server(for: preset.id).value ?? "" : ""
    }

    private static func problem(_ error: StreamDestinationError, plainAllowed: Bool) -> LiveStreamProblem {
        switch error {
        case .notRTMPS: .notRTMPS(plainAllowed: plainAllowed)
        case .invalidServerURL: .invalidServer
        case .emptyKey: .emptyKey
        case .keyLooksLikeURL: .keyLooksLikeURL
        }
    }
}

/// Carries status from the publisher's queue to the main actor at most twice a second, except that
/// a change of phase or health always goes at once.
final class StatusRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> MonotonicInstant
    // Guarded by `lock`.
    private var last: (status: StreamRun.Status, at: MonotonicInstant)?
    private var cancelled = false
    /// Set once before the publisher starts.
    var deliver: (@Sendable (StreamRun.Status, MonotonicInstant) -> Void)?

    init(now: @escaping @Sendable () -> MonotonicInstant) { self.now = now }

    func offer(_ status: StreamRun.Status) {
        let instant = now()
        lock.lock()
        if cancelled {
            lock.unlock()
            return
        }
        if let last, last.status.phase == status.phase, last.status.health == status.health,
            instant - last.at < .milliseconds(500)
        {
            lock.unlock()
            return
        }
        last = (status, instant)
        lock.unlock()
        deliver?(status, instant)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

#if os(iOS)
    /// The device microphone behind the coordinator's audio seam.
    @MainActor final class MicrophoneCapture: LiveStreamAudioCapture {
        private let microphone = StreamMicrophone()
        func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
            try microphone.start(onBuffer: onBuffer)
        }
        func stop() { microphone.stop() }
    }
#endif
#endif
