#if canImport(VideoToolbox) && canImport(Network)
import AVFoundation
import CoreVideo
import MonitorPresentation
import OpenCineApple
import OpenCineCore
@testable import OpenCineStreaming
import OpenCineStreamingApple
import Testing

@testable import OpenCineAppKitApple

/// The live stream composition over scripted fakes: no socket, no encoder, no keychain, no camera.
/// SIMULATED: the publisher's status is scripted.
/// The coordinator is `@Observable` (macOS 14 on the host), so each test opens with an availability guard.
@MainActor @Suite struct LiveStreamCoordinatorTests {
    /// Every call the coordinator makes into the host app, in order.
    @MainActor final class Host {
        var route: StreamConnectionRoute? = .sharedWiFi
        var source: StreamSourceFormat? = StreamSourceFormat(width: 1280, height: 720, frameRate: Rational(30, 1))
        var calls: [String] = []
        var tap: MonitorCleanPictureTap?
        var microphoneAllowed = true
        var defaults = UserDefaults(suiteName: "live-stream-\(UUID())")!

        var value: LiveStreamHost {
            LiveStreamHost(
                keychainService: "test.live-stream", defaults: defaults,
                route: { [self] in calls.append("route"); return route },
                source: { [self] in calls.append("source"); return source },
                attachPicture: { [self] in calls.append($0 == nil ? "detach" : "attach"); tap = $0 },
                microphoneAccess: { [self] in calls.append("microphone"); return microphoneAllowed })
        }
    }

    final class Keys: LiveStreamKeyStoring, @unchecked Sendable {
        var keys: [String: String] = [:]
        var servers: [String: String] = [:]
        var locked = false
        func key(for presetID: String) -> StreamKeyStore.Lookup {
            locked ? .unavailable(-25308) : keys[presetID].map { .stored($0) } ?? .absent
        }
        func server(for presetID: String) -> StreamKeyStore.Lookup {
            locked ? .unavailable(-25308) : servers[presetID].map { .stored($0) } ?? .absent
        }
        func save(key: String, server: String?, for presetID: String) -> Bool {
            keys[presetID] = key
            servers[presetID] = server
            return true
        }
        func remove(for presetID: String) -> Bool {
            keys[presetID] = nil
            servers[presetID] = nil
            return true
        }
    }

    final class Publisher: LiveStreamPublishing, @unchecked Sendable {
        let destination: StreamDestination
        let format: StreamOutputFormat
        var started = false
        var stopped = false
        init(destination: StreamDestination, format: StreamOutputFormat) {
            self.destination = destination
            self.format = format
        }
        func onStatus(_ handler: @escaping @Sendable (StreamRun.Status) -> Void) {}
        func start() { started = true }
        func stop() { stopped = true }
        func submitVideo(_ buffer: CVPixelBuffer) {}
        func submitAudio(_ buffer: AVAudioPCMBuffer) {}
    }

    final class Audio: LiveStreamAudioCapture {
        var running = false
        func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws { running = true }
        func stop() { running = false }
    }

    @available(macOS 14.0, *)
    struct Rig {
        let coordinator: LiveStreamCoordinator
        let host: Host
        let keys: Keys
        let audio: Audio
        let publishers: () -> [Publisher]
    }

    nonisolated static let start = MonotonicInstant(.seconds(1))

    @available(macOS 14.0, *)
    func rig(savedKey: Bool = true, host: Host = Host()) -> Rig {
        let keys = Keys()
        if savedKey { keys.keys["twitch"] = "live_SECRET" }
        let audio = Audio()
        var made: [Publisher] = []
        let coordinator = LiveStreamCoordinator(
            host: host.value, keys: keys, audio: audio,
            makePublisher: { destination, format, _ in
                let publisher = Publisher(destination: destination, format: format)
                made.append(publisher)
                return publisher
            },
            now: { Self.start })
        coordinator.selectService("twitch")
        return Rig(coordinator: coordinator, host: host, keys: keys, audio: audio, publishers: { made })
    }

    static func status(_ phase: StreamRun.Phase, liveSince: MonotonicInstant? = nil,
        health: StreamRun.Health = .good) -> StreamRun.Status {
        StreamRun.Status(phase: phase, liveSince: liveSince, sentBitrateBps: 3_000_000, videoBitrateBps: 3_000_000,
            droppedVideoGroups: 0, droppedAudioPackets: 0, health: health)
    }

    @Test func startStreamsTheSavedKeyAtTheSourcesQuality() async throws {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        await r.coordinator.begin()
        let publisher = try #require(r.publishers().first)
        #expect(publisher.started)
        #expect(publisher.destination.host == "ingest.global-contribute.live-video.net")
        #expect(publisher.destination.isEncrypted)
        #expect(publisher.format.width == 1280 && publisher.format.height == 720)
        #expect(r.host.tap != nil && r.audio.running)
        #expect(r.coordinator.settingsState.phase == .connecting)
        #expect(r.coordinator.settingsState.isLocked)
    }

    @Test func cameraWiFiBlocksGoLiveWithTheReason() async {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        r.host.route = .cameraWiFi
        #expect(r.coordinator.monitorState?.control.isEnabled == false)
        #expect(r.coordinator.settingsState.eligibilityNote == LiveStreamEligibility.cameraWiFi.reason)
        await r.coordinator.begin()
        #expect(r.publishers().isEmpty)
        r.host.route = nil
        #expect(r.coordinator.settingsState.eligibility == .noCamera)
    }

    @Test func monitorControlWaitsForASavedKey() {
        guard #available(macOS 14.0, *) else { return }
        let r = rig(savedKey: false)
        #expect(r.coordinator.monitorState == nil)
        r.coordinator.saveKey("live_NEW")
        #expect(r.coordinator.monitorState != nil)
        #expect(r.coordinator.settingsState.key == .saved)
    }

    @Test func backgroundEndsTheStreamAndOffersRestart() async throws {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        await r.coordinator.begin()
        r.coordinator.receive(Self.status(.live, liveSince: Self.start), at: Self.start + .seconds(5))
        #expect(r.coordinator.monitorState?.control.title == "LIVE 0:05")
        r.coordinator.sceneDidEnterBackground()
        let first = try #require(r.publishers().first)
        #expect(first.stopped && !r.audio.running && r.host.tap == nil)
        #expect(r.coordinator.monitorState?.end == .background)
        #expect(r.coordinator.monitorState?.end?.offersRestart == true)
        await r.coordinator.begin()
        #expect(r.publishers().count == 2 && r.publishers()[1].started)
        #expect(r.coordinator.monitorState?.end == nil)
    }

    @Test func startNeverSendsACameraCommand() async {
        guard #available(macOS 14.0, *) else { return }
        // The host's closures are the coordinator's only way into the app: it reads the route and the
        // source, attaches the picture tap and asks the app for the microphone. Nothing reaches the camera.
        let r = rig()
        await r.coordinator.begin()
        r.coordinator.receive(Self.status(.live, liveSince: Self.start), at: Self.start)
        r.coordinator.stop()
        #expect(Set(r.host.calls).isSubset(of: ["route", "source", "attach", "detach", "microphone"]))
        #expect(r.host.calls.filter { $0 == "attach" }.count == 1)
        #expect(r.host.calls.last == "detach")
    }

    @Test func streamFailureLeavesTheMonitorRunning() async {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        await r.coordinator.begin()
        r.coordinator.receive(Self.status(.live, liveSince: Self.start), at: Self.start)
        let before = r.host.calls.count
        r.coordinator.receive(Self.status(.ended(.refused(reason: "Stream key rejected"))), at: Self.start + .seconds(1))
        // Only the stream's own tap comes off; the monitor and camera are not touched.
        #expect(Array(r.host.calls[before...]).filter { $0 != "route" && $0 != "source" } == ["detach"])
        #expect(!r.audio.running)
        #expect(r.coordinator.monitorState?.end == .refused(reason: "Stream key rejected"))
        #expect(r.coordinator.settingsState.phase == .ended(.refused(reason: "Stream key rejected")))
        #expect(!r.coordinator.isRunning)
    }

    @Test func firstConnectFailureEndsAsUnreachable() async throws {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        await r.coordinator.begin()
        r.coordinator.receive(Self.status(.reconnecting(attempt: 1), health: .offline), at: Self.start + .seconds(1))
        #expect(try #require(r.publishers().first).stopped)
        #expect(r.coordinator.monitorState?.end == .unreachable)
    }

    @Test func reconnectAfterGoingLiveKeepsTheStream() async throws {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        await r.coordinator.begin()
        r.coordinator.receive(Self.status(.live, liveSince: Self.start), at: Self.start)
        r.coordinator.receive(Self.status(.reconnecting(attempt: 2), liveSince: Self.start, health: .offline),
            at: Self.start + .seconds(30))
        #expect(try #require(r.publishers().first).stopped == false)
        #expect(r.coordinator.monitorState?.control.accessibilityLabel == "Reconnecting, attempt 2")
        #expect(r.coordinator.monitorState?.status?.health == .offline)
    }

    @Test func deniedMicrophoneBlocksGoLive() async {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        r.host.microphoneAllowed = false
        await r.coordinator.begin()
        #expect(r.publishers().isEmpty && r.host.tap == nil)
        #expect(r.coordinator.monitorState?.end == .microphoneDenied)
    }

    @Test func saveKeyAppliesEachServicesSchemeRule() {
        guard #available(macOS 14.0, *) else { return }
        let r = rig(savedKey: false)
        r.coordinator.selectService("custom")
        r.coordinator.setServer("rtmp://push.example.com/live")
        #expect(r.coordinator.settingsState.showsPlainWarning)
        r.coordinator.saveKey("custom-key")
        #expect(r.keys.servers["custom"] == "rtmp://push.example.com/live")
        #expect(r.coordinator.settingsState.key == .saved)
        #expect(r.coordinator.monitorState?.encrypted == false)

        r.coordinator.selectService("instagram")
        r.coordinator.setServer("rtmp://edge.example.com/rtmp")
        r.coordinator.saveKey("ig-key")
        #expect(r.keys.keys["instagram"] == nil)
        #expect(r.coordinator.settingsState.problem == .notRTMPS(plainAllowed: false))

        r.coordinator.setServer("rtmps://edge.example.com/rtmp")
        r.coordinator.saveKey("https://not-a-key")
        #expect(r.coordinator.settingsState.problem == .keyLooksLikeURL)
    }

    @Test func lockedKeychainReadsUnavailableNotAbsent() {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        r.keys.locked = true
        r.coordinator.selectService("youtube")
        #expect(r.coordinator.settingsState.key == .unavailable)
        #expect(!r.coordinator.settingsState.offersKeyEntry)
    }

    @Test func removeForgetsTheKeyAndHidesTheControl() {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        r.coordinator.removeKey()
        #expect(r.keys.keys["twitch"] == nil)
        #expect(r.coordinator.settingsState.key == .absent)
        #expect(r.coordinator.monitorState == nil)
    }

    @Test func warningsShowOnlyWhileAStreamRuns() async {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        r.coordinator.updateDeviceConditions(hot: true, lowBattery: false)
        #expect(r.coordinator.monitorState?.warning == nil)
        await r.coordinator.begin()
        r.coordinator.receive(Self.status(.live, liveSince: Self.start), at: Self.start)
        r.coordinator.updateDeviceConditions(hot: true, lowBattery: true)
        #expect(r.coordinator.monitorState?.warning == .hot)
        r.coordinator.updateDeviceConditions(hot: false, lowBattery: true)
        #expect(r.coordinator.monitorState?.warning == .lowBattery)
        #expect(r.coordinator.isRunning)
    }

    @Test func servicesFollowThePresetTableWithCustomLast() {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        let ids = r.coordinator.settingsState.services.map(\.id)
        #expect(ids == StreamServicePreset.all.map(\.id) + ["custom"])
        #expect(r.coordinator.settingsState.services.last?.acceptsPlainServer == true)
    }

    @Test func theMicrophoneIsAskedThroughTheAppsGateAfterTheConfirmation() async {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        #expect(!r.host.calls.contains("microphone"), "Nothing asks before the operator confirms")
        await r.coordinator.begin()
        #expect(r.host.calls.filter { $0 == "microphone" }.count == 1)
        #expect(r.publishers().count == 1)
    }

    @Test func theAppPillShowsOnlyWhileRunningWithNoMonitorControls() async {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        r.coordinator.monitorControlsAppeared()
        #expect(r.coordinator.pillState == nil, "Idle: no pill")
        await r.coordinator.begin()
        #expect(r.coordinator.pillState == nil, "The monitor shows the control")
        r.coordinator.monitorControlsDisappeared()
        #expect(r.coordinator.pillState?.title == "Connecting")
        r.coordinator.receive(Self.status(.live, liveSince: Self.start), at: Self.start + .seconds(65))
        #expect(r.coordinator.pillState?.title == "LIVE 1:05")
        r.coordinator.monitorControlsAppeared()
        #expect(r.coordinator.pillState == nil)
        r.coordinator.monitorControlsDisappeared()
        r.coordinator.stop()
        #expect(r.coordinator.pillState == nil, "Stopped: no pill")
        r.coordinator.monitorControlsDisappeared()
        r.coordinator.monitorControlsAppeared()
        #expect(r.coordinator.monitorControlsOnScreen == 1, "Never counts below zero")
    }

    @Test func upscaledChoiceStreams1920x1080() async throws {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        #expect(r.coordinator.settingsState.qualityOptions.map(\.id) == ["cameraFeed", "upscaled1080p"])
        #expect(r.coordinator.settingsState.selectedQualityID == "cameraFeed")
        r.coordinator.selectQuality("upscaled1080p")
        let quality = try #require(r.coordinator.settingsState.quality)
        #expect(quality.kind == .upscaled && quality.width == 1920 && quality.height == 1080)
        #expect(r.coordinator.monitorState?.quality?.line.hasPrefix("1080p upscaled") == true)
        await r.coordinator.begin()
        let publisher = try #require(r.publishers().first)
        #expect(publisher.format.width == 1920 && publisher.format.height == 1080)
        #expect(publisher.format.videoBitrateBps == 6_000_000)
    }

    @Test func rememberedChoiceFallsBackWhenNotOffered() async throws {
        guard #available(macOS 14.0, *) else { return }
        let host = Host()
        let r = rig(host: host)
        r.coordinator.selectQuality("upscaled1080p")
        host.source = StreamSourceFormat(width: 1920, height: 1080, frameRate: Rational(30, 1))
        #expect(r.coordinator.settingsState.qualityOptions.map(\.id) == ["cameraFeed"])
        #expect(r.coordinator.settingsState.selectedQualityID == "cameraFeed")
        #expect(r.coordinator.settingsState.quality?.kind == .source)
        await r.coordinator.begin()
        #expect(r.publishers().first?.format.width == 1920)
        r.coordinator.stop()
        host.source = StreamSourceFormat(width: 1280, height: 720, frameRate: nil)
        let again = rig(host: host)
        #expect(again.coordinator.settingsState.selectedQualityID == "upscaled1080p")
        again.coordinator.selectQuality("nope")
        #expect(again.coordinator.settingsState.selectedQualityID == "upscaled1080p")
    }

    @Test func qualityIsLockedWhileLive() async throws {
        guard #available(macOS 14.0, *) else { return }
        let r = rig()
        await r.coordinator.begin()
        r.coordinator.selectQuality("upscaled1080p")
        #expect(r.coordinator.settingsState.selectedQualityID == "cameraFeed")
        #expect(r.coordinator.settingsState.quality?.width == 1280)
    }
}
#endif
