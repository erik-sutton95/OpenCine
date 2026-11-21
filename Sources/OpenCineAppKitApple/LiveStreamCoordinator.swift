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
    /// A camera that can publish its own stream to this device ("1080p from camera"); `nil` for
    /// an app or camera without one.
    public var camera: (any LiveStreamCameraSource)?

    public init(
        keychainService: String, defaults: UserDefaults = .standard,
        route: @escaping @MainActor () -> StreamConnectionRoute?,
        source: @escaping @MainActor () -> StreamSourceFormat?,
        attachPicture: @escaping @MainActor (MonitorCleanPictureTap?) -> Void,
        microphoneAccess: @escaping @MainActor () async -> Bool,
        camera: (any LiveStreamCameraSource)? = nil
    ) {
        self.keychainService = keychainService
        self.defaults = defaults
        self.route = route
        self.source = source
        self.attachPicture = attachPicture
        self.microphoneAccess = microphoneAccess
        self.camera = camera
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
        let choice: StreamQualityChoice
        let encrypted: Bool
        let relay: StatusRelay
    }

    @ObservationIgnored private let host: LiveStreamHost
    @ObservationIgnored private let keys: any LiveStreamKeyStoring
    @ObservationIgnored private let audio: (any LiveStreamAudioCapture)?
    @ObservationIgnored private let makePublisher:
        (StreamDestination, StreamOutputFormat, StreamPictureFitter.Mode) -> any LiveStreamPublishing
    @ObservationIgnored private let now: @Sendable () -> MonotonicInstant
    @ObservationIgnored private let makeCameraRelay: () -> any LiveStreamCameraRelaying
    @ObservationIgnored private let sleep: (Duration) async -> Void

    private var selectedID: String
    /// The operator's remembered Quality choice; it applies only while offered for the source.
    private var rememberedQuality: StreamQualityChoice
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
    /// The camera's own stream while "1080p from camera" runs, from Go live until it is returned.
    private var cameraRun: CameraRun?
    private var cameraStatus: LiveStreamCameraStatus?
    /// Ending the camera's stream (`endPublishing` then `finished`), awaited at termination.
    @ObservationIgnored private var cameraEnding: Task<Void, Never>?
    @ObservationIgnored private var starting = false
    /// Monitor overlays on screen now; with none, a running stream shows the app-level pill.
    private(set) var monitorControlsOnScreen = 0

    private static let presets = StreamServicePreset.all + [.custom]
    private static let serviceKey = "opencine.livestream.service"
    private static let monitorKey = "opencine.livestream.showOnMonitor"
    private static let qualityKey = "opencine.livestream.quality"
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
        makeCameraRelay: @escaping () -> any LiveStreamCameraRelaying = { CameraStreamRelayAdapter() },
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> MonotonicInstant
    ) {
        self.host = host
        self.keys = keys
        self.audio = audio
        self.makePublisher = makePublisher
        self.makeCameraRelay = makeCameraRelay
        self.sleep = sleep
        self.now = now
        let saved = host.defaults.string(forKey: Self.serviceKey)
        selectedID = Self.presets.contains { $0.id == saved } ? saved ?? "" : Self.presets[0].id
        showOnMonitor = host.defaults.object(forKey: Self.monitorKey) as? Bool ?? true
        rememberedQuality = host.defaults.string(forKey: Self.qualityKey).flatMap(StreamQualityChoice.init) ?? .cameraFeed
        reloadKey()
    }

    // MARK: Values

    private var preset: StreamServicePreset { Self.presets.first { $0.id == selectedID } ?? Self.presets[0] }

    public var isRunning: Bool { phase.isRunning }

    private var eligibility: LiveStreamEligibility {
        // The camera publishes over a shared network of its own, so its route does not matter.
        if effectiveQuality == .camera1080p { return .allowed }
        return switch host.route() {
        case .cameraWiFi: .cameraWiFi
        case nil: .noCamera
        case .usbCable, .captureCard, .sharedWiFi, .deviceHotspot: .allowed
        }
    }

    /// The choices offered for the current source, and the camera's own stream when it has one.
    private var offeredQualities: [StreamQualityChoice] {
        StreamQualityChoice.offered(for: host.source()) + (cameraPublishing == nil ? [] : [.camera1080p])
    }

    private var cameraPublishing: CameraStreamPublishing? { host.camera?.publishing }

    /// The camera's saved shared networks, this device's hotspot first.
    private var cameraNetworks: [LiveStreamNetwork] {
        let networks = host.camera?.networks ?? []
        return networks.filter(\.isHotspot) + networks.filter { !$0.isHotspot }
    }

    /// The remembered choice while it is offered (and usable), else the camera feed.
    private var effectiveQuality: StreamQualityChoice {
        if let running { return running.choice }
        if cameraRun != nil { return .camera1080p }
        guard offeredQualities.contains(rememberedQuality) else { return .cameraFeed }
        if rememberedQuality == .camera1080p, cameraNetworks.isEmpty { return .cameraFeed }
        return rememberedQuality
    }

    /// The camera's own picture as a source: its size at the frame rate nearest the feed's.
    private func cameraSource(_ publishing: CameraStreamPublishing) -> StreamSourceFormat {
        let rate = publishing.frameRate(near: host.source()?.frameRate.map { Int($0.doubleValue.rounded()) })
        return StreamSourceFormat(width: publishing.width, height: publishing.height, frameRate: Rational(rate, 1))
    }

    private var format: StreamOutputFormat? {
        if let running { return running.format }
        if let cameraRun { return cameraRun.format }
        let choice = effectiveQuality
        if choice == .camera1080p, let publishing = cameraPublishing {
            return StreamOutputFormat.resolve(selected: cameraSource(publishing), connected: [], preset: preset, choice: choice)
        }
        guard let source = host.source() else { return nil }
        return StreamOutputFormat.resolve(selected: source, connected: [], preset: preset, choice: choice)
    }

    private var quality: LiveStreamQuality? {
        let kind: LiveStreamQualityKind = switch effectiveQuality {
        case .cameraFeed: .source
        case .upscaled1080p: .upscaled
        case .camera1080p: .camera
        }
        return format.map {
            LiveStreamQuality(width: $0.width, height: $0.height, framesPerSecond: $0.frameRate.doubleValue,
                videoBitrateBps: $0.videoBitrateBps, kind: kind)
        }
    }

    private var qualityOptions: [LiveStreamQualityOption] {
        offeredQualities.map { choice in
            switch choice {
            case .cameraFeed: LiveStreamQualityOption(id: choice.rawValue, title: LiveStreamCopy.qualityCameraFeed)
            case .upscaled1080p:
                LiveStreamQualityOption(id: choice.rawValue, title: LiveStreamCopy.qualityUpscaled,
                    detail: LiveStreamCopy.qualityUpscaledDetail)
            case .camera1080p:
                LiveStreamQualityOption(id: choice.rawValue, title: LiveStreamCopy.qualityCamera,
                    detail: LiveStreamCopy.qualityCameraDetail,
                    unavailableReason: cameraNetworks.isEmpty ? LiveStreamCopy.qualityCameraNeedsNetwork : nil)
            }
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
            showOnMonitor: showOnMonitor, phase: phase, problem: problem, qualityOptions: qualityOptions,
            selectedQualityID: effectiveQuality.rawValue)
    }

    /// What the monitor shows, or `nil` when the Go live control is hidden (no saved key, or the
    /// operator turned it off) and nothing is running or to report.
    public var monitorState: LiveStreamMonitorState? {
        guard phase.isRunning || end != nil || (showOnMonitor && keyState == .saved) else { return nil }
        return LiveStreamMonitorState(
            control: LiveStreamControlState(phase: phase, eligibility: eligibility, serviceName: preset.displayName,
                elapsedSeconds: status?.elapsedSeconds ?? 0),
            serviceName: preset.displayName, quality: quality, encrypted: encrypted, status: status, end: end,
            warning: phase.isRunning ? (hot ? .hot : lowBattery ? .lowBattery : nil) : nil,
            cameraStatus: cameraStatus, networkChoices: networkChoices)
    }

    /// Start buttons per shared network, when the camera's own stream could use more than one.
    private var networkChoices: [LiveStreamNetworkChoice] {
        guard !phase.isRunning, effectiveQuality == .camera1080p else { return [] }
        let networks = cameraNetworks
        return networks.count < 2 ? [] : networks.map { LiveStreamNetworkChoice(id: $0.id, name: $0.name) }
    }

    /// The camera's own stream is running or being started: the app hands the camera to the
    /// stream (no monitoring, no camera controls) until `LiveStreamCameraSource.finished()`.
    public var cameraStreamActive: Bool { cameraRun != nil }

    /// The relayed picture for the app's full-screen camera monitor while the camera streams.
    public var cameraDisplay: LiveStreamCameraDisplay? { cameraRun?.feed.display }

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

    /// Chooses a Quality option by its id; remembered for the next stream. Ignored while a stream
    /// runs or for an unknown id.
    public func selectQuality(_ id: String) {
        guard !phase.isRunning, let choice = StreamQualityChoice(rawValue: id) else { return }
        rememberedQuality = choice
        host.defaults.set(id, forKey: Self.qualityKey)
    }

    public func setShowOnMonitor(_ value: Bool) {
        showOnMonitor = value
        host.defaults.set(value, forKey: Self.monitorKey)
    }

    // MARK: Going live

    /// Starts a stream after the operator's one confirmation (or the background restart).
    public func start() { Task { await begin() } }

    /// Starts "1080p from camera" over the saved network with this id (the start buttons).
    public func start(network id: String) { Task { await begin(networkID: id) } }

    public func restart() { start() }

    public func stop() {
        guard running != nil || cameraRun != nil else { return }
        finish(.stopped, stopPublisher: true)
    }

    /// Asks the camera to start its stream again (after it was lost or stopped answering); the
    /// outgoing stream stays up meanwhile.
    public func retryCamera() {
        guard let cameraRun, cameraStatus?.offersRetry == true else { return }
        cameraStatus = .recovering
        cameraRun.task = Task { await runCamera(cameraRun, attempts: 1) }
    }

    /// The app is about to quit: end the camera's stream (bounded by the camera source) so the
    /// camera does not stay live with nothing to receive it.
    public func prepareForTermination() async {
        if running != nil || cameraRun != nil { finish(.stopped, stopPublisher: true) }
        await cameraEnding?.value
    }

    public func dismissNotice() {
        end = nil
        if case .ended = phase { phase = .idle }
    }

    /// The app left the screen: streaming is foreground only, so the stream ends now and a notice
    /// offers one tap restart on return.
    public func sceneDidEnterBackground() {
        guard running != nil || cameraRun != nil else { return }
        finish(.background, stopPublisher: true)
    }

    /// Warn on heat or a low battery while live; never stop for them.
    public func updateDeviceConditions(hot: Bool, lowBattery: Bool) {
        self.hot = hot
        self.lowBattery = lowBattery
    }

    func begin(networkID: String? = nil) async {
        guard !phase.isRunning, !starting, cameraRun == nil else { return }
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
        let choice = effectiveQuality
        if choice == .camera1080p {
            return beginCamera(destination: destination, networkID: networkID)
        }
        let format = StreamOutputFormat.resolve(
            selected: host.source() ?? Self.fallbackSource, connected: [], preset: preset, choice: choice)
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
        running = Running(publisher: publisher, format: format, choice: choice, encrypted: destination.isEncrypted, relay: relay)
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
        guard running != nil || cameraRun != nil else { return }
        if let running {
            running.relay.cancel()
            if stopPublisher { running.publisher.stop() }
        }
        if let cameraRun {
            endCamera(cameraRun)
        } else {
            host.attachPicture(nil)
            audio?.stop()
        }
        self.running = nil
        cameraRun = nil
        cameraStatus = nil
        status = nil
        phase = reason == .stopped ? .idle : .ended(reason)
        end = reason == .stopped ? nil : reason
    }

    // MARK: 1080p from camera

    private func beginCamera(destination: StreamDestination, networkID: String?) {
        let networks = cameraNetworks
        guard let camera = host.camera, let publishing = camera.publishing,
            let network = networkID.flatMap({ id in networks.first { $0.id == id } }) ?? networks.first
        else { return }
        let source = cameraSource(publishing)
        let format = StreamOutputFormat.resolve(selected: source, connected: [], preset: preset, choice: .camera1080p)
        let run = CameraRun(camera: camera, network: network, destination: destination, format: format,
            frameRate: source.frameRate.map { Int($0.doubleValue.rounded()) } ?? 30)
        cameraRun = run
        cameraStatus = .starting
        phase = .connecting
        status = LiveStreamStatusState(phase: .connecting, elapsedSeconds: 0, sentBitrateBps: 0, droppedGroups: 0,
            health: .offline)
        run.task = Task { await runCamera(run, attempts: 2) }
    }

    /// Attempts to get the camera's picture: a failed start pauses and tries again; a picture
    /// that went away is tried again at once (`attempts` counts the tries left).
    private func runCamera(_ run: CameraRun, attempts: Int) async {
        var left = attempts
        var lastError: LiveStreamCameraError?
        while left > 0 {
            left -= 1
            switch await attemptCamera(run) {
            case .cancelled:
                return
            case .lost:
                guard cameraRun === run else { return }
                cameraStatus = .recovering
                left = 1
                lastError = nil
            case .failed(let error):
                lastError = error ?? lastError
                if left > 0 {
                    await pause(.seconds(3))
                    if Task.isCancelled || cameraRun !== run { return }
                }
            }
        }
        guard cameraRun === run, !Task.isCancelled else { return }
        if run.feed.publisher == nil {
            finish(lastError == .notResponding ? .cameraNotResponding : .cameraDidNotStart, stopPublisher: false)
        } else {
            cameraStatus = lastError == .notResponding ? .notResponding : .lost
        }
    }

    private enum CameraAttempt {
        case cancelled
        /// The picture arrived and later went away.
        case lost
        case failed(LiveStreamCameraError?)
    }

    private enum CameraSignal {
        case relay(LiveStreamCameraRelayEvent)
        case timeout
    }

    /// One try: open a receiver under a fresh key, ask the camera to publish to it, and wait for its
    /// first picture (60 s at most). The first picture of the stream starts the outgoing publish.
    private func attemptCamera(_ run: CameraRun) async -> CameraAttempt {
        let address: String
        do {
            address = try await run.camera.prepare(run.network)
        } catch {
            return Task.isCancelled ? .cancelled : .failed(error as? LiveStreamCameraError)
        }
        guard !Task.isCancelled, cameraRun === run else { return .cancelled }
        let (signals, continuation) = AsyncStream<CameraSignal>.makeStream()
        let token = StreamReceiverToken.random()
        let relay = makeCameraRelay()
        run.relay = relay
        let feed = run.feed
        relay.open(token: token, video: { feed.video($0) }, audio: { feed.audio($0) },
            events: { continuation.yield(.relay($0)) })
        run.cameraPublishing = true
        do {
            try await run.camera.startPublishing(
                to: token.publishURL(host: address), network: run.network, frameRate: run.frameRate)
        } catch {
            if Task.isCancelled { return .cancelled }
            await tearDownAttempt(run)
            return .failed(error as? LiveStreamCameraError)
        }
        let sleep = sleep
        let timer = Task {
            await sleep(.seconds(60))
            if !Task.isCancelled { continuation.yield(.timeout) }
        }
        defer {
            timer.cancel()
            continuation.finish()
        }
        var pictured = false
        for await signal in signals {
            guard cameraRun === run else { return .cancelled }
            switch signal {
            case .relay(.connected):
                continue
            case .relay(.firstPicture):
                timer.cancel()
                pictured = true
                startCameraPublisher(run)
                cameraStatus = .live
            case .timeout:
                if pictured { continue }
                await tearDownAttempt(run)
                return .failed(nil)
            case .relay(.lost), .relay(.listenFailed):
                await tearDownAttempt(run)
                return pictured ? .lost : .failed(nil)
            }
        }
        return .cancelled
    }

    /// Closes this try's receiver and ends the camera's publish, so the next try starts clean.
    private func tearDownAttempt(_ run: CameraRun) async {
        run.relay?.close()
        run.relay = nil
        if run.cameraPublishing {
            run.cameraPublishing = false
            await run.camera.endPublishing()
        }
    }

    /// Waits `duration` unless the task is cancelled first.
    private func pause(_ duration: Duration) async {
        let (done, continuation) = AsyncStream<Void>.makeStream()
        let sleep = sleep
        Task {
            await sleep(duration)
            continuation.yield()
        }
        for await _ in done { break }
    }

    /// The outgoing stream, once: the camera's pictures and sound, no microphone, no picture tap.
    private func startCameraPublisher(_ run: CameraRun) {
        guard run.feed.publisher == nil else { return }
        let publisher = makePublisher(run.destination, run.format, preset.aspect == .portrait9x16 ? .centerCrop : .fit)
        let relay = StatusRelay(now: now)
        relay.deliver = { [weak self] status, instant in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.relayed(status, at: instant, from: relay) }
            }
        }
        publisher.onStatus { relay.offer($0) }
        running = Running(publisher: publisher, format: run.format, choice: .camera1080p,
            encrypted: run.destination.isEncrypted, relay: relay)
        run.feed.publisher = publisher
        publisher.start()
    }

    /// Stops this camera run now and returns the camera in the background: the receiver closes at
    /// once, then the camera is told to end its stream, then the app gets it back.
    private func endCamera(_ run: CameraRun) {
        let task = run.task
        task?.cancel()
        run.relay?.close()
        run.relay = nil
        run.feed.publisher = nil
        let previous = cameraEnding
        cameraEnding = Task {
            await previous?.value
            await task?.value
            if run.cameraPublishing {
                run.cameraPublishing = false
                await run.camera.endPublishing()
            }
            run.camera.finished()
        }
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

/// One "1080p from camera" stream from Go live until the camera is returned.
@MainActor final class CameraRun {
    let camera: any LiveStreamCameraSource
    let network: LiveStreamNetwork
    let destination: StreamDestination
    let format: StreamOutputFormat
    let frameRate: Int
    let feed = CameraFeed()
    var task: Task<Void, Never>?
    /// This try's receiver.
    var relay: (any LiveStreamCameraRelaying)?
    /// The camera was asked to publish and has not been told to end.
    var cameraPublishing = false

    init(camera: any LiveStreamCameraSource, network: LiveStreamNetwork, destination: StreamDestination,
        format: StreamOutputFormat, frameRate: Int) {
        self.camera = camera
        self.network = network
        self.destination = destination
        self.format = format
        self.frameRate = frameRate
    }
}

/// Where the camera's decoded pictures and sound go, from the receiver's threads: the outgoing
/// publisher (once the first picture started it) and the monitor's display.
final class CameraFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var _publisher: (any LiveStreamPublishing)?
    let display = LiveStreamCameraDisplay()

    var publisher: (any LiveStreamPublishing)? {
        get { lock.withLock { _publisher } }
        set { lock.withLock { _publisher = newValue } }
    }

    func video(_ buffer: CVPixelBuffer) {
        publisher?.submitVideo(buffer)
        display.show(buffer)
    }

    func audio(_ buffer: AVAudioPCMBuffer) { publisher?.submitAudio(buffer) }
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
