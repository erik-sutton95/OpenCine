#if canImport(VideoToolbox) && canImport(Network)
import AVFoundation
import CoreVideo
import MonitorPresentation
import OpenCineApple
import OpenCineCore
@testable import OpenCineStreaming
import OpenCineStreamingApple
import Observation
import Testing

@testable import OpenCineAppKitApple

/// "1080p from camera": the coordinator drives a camera that publishes its own stream to this
/// device and relays it outward. SIMULATED: the camera, the receiver and the publisher are scripted
/// fakes; every wait is an event from a fake, never a clock.
@MainActor @Suite struct LiveStreamCameraRelayTests {
    /// A signal the test awaits: every call the fakes see, in order.
    @MainActor final class Log {
        private(set) var calls: [String] = []
        private var waiters: [(String, CheckedContinuation<Void, Never>)] = []

        func add(_ call: String) {
            calls.append(call)
            let ready = waiters.filter { call.hasPrefix($0.0) }
            waiters.removeAll { call.hasPrefix($0.0) }
            for waiter in ready { waiter.1.resume() }
        }

        /// Returns once a call starting with `prefix` has happened (now or later).
        func wait(for prefix: String, count: Int = 1) async {
            while calls.filter({ $0.hasPrefix(prefix) }).count < count {
                await withCheckedContinuation { waiters.append((prefix, $0)) }
            }
        }

        func count(_ prefix: String) -> Int { calls.filter { $0.hasPrefix(prefix) }.count }
    }

    @MainActor final class Camera: LiveStreamCameraSource {
        let log: Log
        var publishing: CameraStreamPublishing? = CameraStreamPublishing(
            width: 1920, height: 1080, frameRates: [25, 30], codecs: [.hevc, .h264], takesLUT: false,
            experimental: false)
        var networks: [LiveStreamNetwork] = [LiveStreamNetwork(id: "hotspot", name: "Phone hotspot", isHotspot: true)]
        /// Errors the next `startPublishing` calls throw, in order.
        var startErrors: [any Error] = []

        init(log: Log) { self.log = log }

        func prepare(_ network: LiveStreamNetwork) async throws -> String {
            log.add("prepare \(network.id)")
            return "172.20.10.1"
        }

        func startPublishing(to url: String, network: LiveStreamNetwork, frameRate: Int) async throws {
            log.add("startPublishing \(url) \(frameRate)")
            if !startErrors.isEmpty { throw startErrors.removeFirst() }
        }

        func endPublishing() async { log.add("endPublishing") }
        func finished() { log.add("finished") }
    }

    final class Relay: LiveStreamCameraRelaying, @unchecked Sendable {
        let log: Log
        var events: (@Sendable (LiveStreamCameraRelayEvent) -> Void)?
        var token: StreamReceiverToken?
        var video: (@Sendable (CVPixelBuffer) -> Void)?
        init(log: Log) { self.log = log }
        func open(
            token: StreamReceiverToken, video: @escaping @Sendable (CVPixelBuffer) -> Void,
            audio: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
            events: @escaping @Sendable (LiveStreamCameraRelayEvent) -> Void
        ) {
            self.token = token
            self.video = video
            self.events = events
            MainActor.assumeIsolated { log.add("relay.open") }
        }
        func close() { MainActor.assumeIsolated { log.add("relay.close") } }
    }

    /// The coordinator's pauses (the first-picture wait and the retry pause), released by the test.
    @MainActor final class Sleeper {
        let log: Log
        private var pending: [(Duration, CheckedContinuation<Void, Never>)] = []
        init(log: Log) { self.log = log }
        func sleep(_ duration: Duration) async {
            log.add("sleep \(duration.components.seconds)")
            await withCheckedContinuation { pending.append((duration, $0)) }
        }
        /// Ends every pause of `seconds` now (a timeout).
        func elapse(_ seconds: Int64) {
            let due = pending.filter { $0.0.components.seconds == seconds }
            pending.removeAll { $0.0.components.seconds == seconds }
            for item in due { item.1.resume() }
        }
    }

    @available(macOS 14.0, *)
    struct Rig {
        let coordinator: LiveStreamCoordinator
        let host: LiveStreamCoordinatorTests.Host
        let camera: Camera
        let log: Log
        let sleeper: Sleeper
        let relays: () -> [Relay]
        let publishers: () -> [LiveStreamCoordinatorTests.Publisher]
        let audio: LiveStreamCoordinatorTests.Audio

        var relay: Relay { relays().last! }

        func picture() -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
            return buffer!
        }
    }

    @available(macOS 14.0, *)
    func rig() -> Rig {
        let log = Log()
        let host = LiveStreamCoordinatorTests.Host()
        let camera = Camera(log: log)
        host.camera = camera
        let keys = LiveStreamCoordinatorTests.Keys()
        keys.keys["twitch"] = "live_SECRET"
        let audio = LiveStreamCoordinatorTests.Audio()
        let sleeper = Sleeper(log: log)
        var relays: [Relay] = []
        var publishers: [LiveStreamCoordinatorTests.Publisher] = []
        let coordinator = LiveStreamCoordinator(
            host: host.value, keys: keys, audio: audio,
            makePublisher: { destination, format, _ in
                let publisher = LiveStreamCoordinatorTests.Publisher(destination: destination, format: format)
                publishers.append(publisher)
                MainActor.assumeIsolated { log.add("publisher \(format.width)x\(format.height)") }
                return publisher
            },
            makeCameraRelay: {
                let relay = Relay(log: log)
                relays.append(relay)
                return relay
            },
            sleep: { duration in await sleeper.sleep(duration) },
            now: { LiveStreamCoordinatorTests.start })
        coordinator.selectService("twitch")
        coordinator.selectQuality("camera1080p")
        return Rig(coordinator: coordinator, host: host, camera: camera, log: log, sleeper: sleeper,
            relays: { relays }, publishers: { publishers }, audio: audio)
    }

    /// Returns once `condition` holds, woken by the coordinator's observation (no clock, no polling).
    @available(macOS 14.0, *)
    func until(_ condition: @escaping @MainActor () -> Bool) async {
        while !condition() {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = condition() } onChange: { continuation.resume() }
            }
        }
    }

    /// Starts and runs until the camera publishes and its first picture arrives.
    @available(macOS 14.0, *)
    func live(_ r: Rig) async {
        r.coordinator.start()
        await r.log.wait(for: "startPublishing")
        r.relay.events?(.connected)
        r.relay.events?(.firstPicture)
        await r.log.wait(for: "publisher")
    }

    @Test func cameraChoiceNeedsTheCapability() {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        #expect(r.coordinator.settingsState.qualityOptions.map(\.id) == ["cameraFeed", "upscaled1080p", "camera1080p"])
        let option = r.coordinator.settingsState.qualityOptions.last
        #expect(option?.title == "1080p from camera" && option?.isEnabled == true)
        #expect(r.coordinator.settingsState.quality?.line == "1080p from camera, 30 fps, 6 Mbps")
        r.camera.publishing = nil
        #expect(r.coordinator.settingsState.qualityOptions.map(\.id) == ["cameraFeed", "upscaled1080p"])
        #expect(r.coordinator.settingsState.selectedQualityID == "cameraFeed")
    }

    @Test func cameraChoiceListedDisabledWithoutANetwork() {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        r.camera.networks = []
        let option = r.coordinator.settingsState.qualityOptions.last
        #expect(option?.id == "camera1080p")
        #expect(option?.unavailableReason == LiveStreamCopy.qualityCameraNeedsNetwork)
        #expect(r.coordinator.settingsState.selectedQualityID == "cameraFeed")
    }

    @Test func cameraWiFiDoesNotBlockTheCameraChoice() {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        r.host.route = .cameraWiFi
        #expect(r.coordinator.monitorState?.control.isEnabled == true)
    }

    @Test func cameraStartOrderAndNoMicrophone() async throws {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        await live(r)
        #expect(r.log.calls.prefix(4) == [
            "prepare hotspot", "relay.open",
            "startPublishing rtmp://172.20.10.1:1935/live/\(r.relay.token!.value) 30", "sleep 60",
        ])
        #expect(r.log.calls.contains("publisher 1920x1080"))
        #expect(!r.host.calls.contains("microphone") && !r.audio.running)
        #expect(!r.host.calls.contains("attach"))
        #expect(r.coordinator.cameraStreamActive)
        #expect(r.coordinator.monitorState?.cameraStatus == .live)
        let publisher = try #require(r.publishers().first)
        #expect(publisher.started && publisher.format.videoBitrateBps == 6_000_000)
        r.relay.video?(r.picture())
        #expect(publisher.videoFrames == 1)
    }

    @Test func goesLiveOnlyAfterTheFirstPicture() async {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        r.coordinator.start()
        await r.log.wait(for: "sleep 60")
        r.relay.events?(.connected)
        #expect(r.publishers().isEmpty)
        #expect(r.coordinator.monitorState?.cameraStatus == .starting)
        #expect(r.coordinator.settingsState.phase == .connecting)
        r.relay.events?(.firstPicture)
        await r.log.wait(for: "publisher")
        #expect(r.publishers().count == 1)
    }

    @Test func startErrorEndsCleanlyAndRetriesOnce() async {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        r.camera.startErrors = [LiveStreamCameraError.refused("D6"), LiveStreamCameraError.refused("D6")]
        r.coordinator.start()
        await r.log.wait(for: "sleep 3")
        #expect(r.log.calls == ["prepare hotspot", "relay.open", "startPublishing rtmp://172.20.10.1:1935/live/\(r.relays()[0].token!.value) 30",
            "relay.close", "endPublishing", "sleep 3"])
        r.sleeper.elapse(3)
        await r.log.wait(for: "finished")
        #expect(r.log.count("startPublishing") == 2)
        #expect(r.log.count("endPublishing") == 2)
        #expect(r.publishers().isEmpty)
        #expect(r.coordinator.settingsState.phase == .ended(.cameraDidNotStart))
        #expect(r.coordinator.monitorState?.end == .cameraDidNotStart)
        #expect(!r.coordinator.cameraStreamActive)
        #expect(r.relays()[0].token != r.relays()[1].token)
    }

    @Test func aCameraThatStopsAnsweringSaysHowToRestartIt() async {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        r.camera.startErrors = [LiveStreamCameraError.notResponding, LiveStreamCameraError.notResponding]
        r.coordinator.start()
        await r.log.wait(for: "sleep 3")
        r.sleeper.elapse(3)
        await r.log.wait(for: "finished")
        #expect(r.coordinator.settingsState.phase == .ended(.cameraNotResponding))
    }

    @Test func noPictureWithinTheWaitCountsAsAFailedStart() async {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        r.coordinator.start()
        await r.log.wait(for: "sleep 60")
        r.sleeper.elapse(60)
        await r.log.wait(for: "sleep 3")
        #expect(r.log.count("endPublishing") == 1)
        r.sleeper.elapse(3)
        await r.log.wait(for: "startPublishing", count: 2)
        r.relay.events?(.firstPicture)
        await r.log.wait(for: "publisher")
        #expect(r.coordinator.monitorState?.cameraStatus == .live)
    }

    @Test func cameraLossKeepsTheStreamAndRetriesOnce() async throws {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        await live(r)
        let publisher = try #require(r.publishers().first)
        r.relay.events?(.lost)
        await r.log.wait(for: "startPublishing", count: 2)
        #expect(r.coordinator.monitorState?.cameraStatus == .recovering)
        #expect(r.publishers().count == 1)
        #expect(!publisher.stopped)
        #expect(r.log.count("endPublishing") == 1)
        // The restart produces no picture: the slate stays and Retry is offered.
        await r.log.wait(for: "sleep 60", count: 2)
        r.sleeper.elapse(60)
        await until { r.coordinator.monitorState?.cameraStatus == .lost }
        #expect(r.log.count("endPublishing") == 2)
        #expect(!publisher.stopped && r.coordinator.isRunning)
        r.coordinator.retryCamera()
        await r.log.wait(for: "startPublishing", count: 3)
        r.relay.events?(.firstPicture)
        await until { r.coordinator.monitorState?.cameraStatus == .live }
        #expect(r.publishers().count == 1)
    }

    @Test func stopEndsTheCameraStreamAndReturnsTheCamera() async throws {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        await live(r)
        r.coordinator.stop()
        await r.log.wait(for: "finished")
        #expect(try #require(r.publishers().first).stopped)
        #expect(Array(r.log.calls.suffix(3)) == ["relay.close", "endPublishing", "finished"])
        #expect(r.coordinator.settingsState.phase == .idle)
        #expect(!r.coordinator.cameraStreamActive)
        #expect(r.coordinator.monitorState?.cameraStatus == nil)
    }

    @Test func stopWhileTheCameraStartsStillEndsIt() async {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        r.coordinator.start()
        await r.log.wait(for: "sleep 60")
        r.coordinator.stop()
        await r.log.wait(for: "finished")
        #expect(r.log.count("endPublishing") == 1)
        #expect(r.publishers().isEmpty)
    }

    @Test func backgroundEndsTheCameraStreamFirst() async {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        await live(r)
        r.coordinator.sceneDidEnterBackground()
        await r.log.wait(for: "finished")
        #expect(r.log.count("endPublishing") == 1)
        #expect(r.coordinator.settingsState.phase == .ended(.background))
    }

    @Test func severalNetworksAreOfferedHotspotFirst() async {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        r.camera.networks = [
            LiveStreamNetwork(id: "hotspot", name: "es_iphone16", isHotspot: true),
            LiveStreamNetwork(id: "home", name: "Mouse House", isHotspot: false),
        ]
        #expect(r.coordinator.monitorState?.networkChoices.map(\.name) == ["es_iphone16", "Mouse House"])
        r.coordinator.start(network: "home")
        await r.log.wait(for: "prepare")
        #expect(r.log.calls.first == "prepare home")
        r.camera.networks = [r.camera.networks[0]]
        #expect(r.coordinator.monitorState?.networkChoices.isEmpty == true)
    }
}
#endif
