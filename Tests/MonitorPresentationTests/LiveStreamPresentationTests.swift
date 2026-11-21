import MonitorPresentation
import Testing

/// The live stream surface contract (`docs/streaming/ui-contract.md`): what the settings card, the
/// Go live control and the status readout show, enable and announce. The Compose twin mirrors these.
struct LiveStreamPresentationTests {
    static let services = [
        LiveStreamServiceOption(id: "a", name: "Service A", keyHint: "Find the key in A.", needsServer: false,
            acceptsPlainServer: false, vertical: false),
        LiveStreamServiceOption(id: "v", name: "Service V", keyHint: "V issues both.", needsServer: true,
            acceptsPlainServer: false, vertical: true),
        LiveStreamServiceOption(id: "custom", name: "Custom server", keyHint: "Paste both.", needsServer: true,
            acceptsPlainServer: true, vertical: false),
    ]

    static func settings(
        _ selected: String = "a", server: String = "", key: LiveStreamKeyState = .saved,
        eligibility: LiveStreamEligibility = .allowed, phase: LiveStreamPhase = .idle, sourceHeight: Int? = 720
    ) -> LiveStreamSettingsState {
        LiveStreamSettingsState(services: services, selectedID: selected, server: server, key: key,
            quality: LiveStreamQuality(width: 1280, height: 720, framesPerSecond: 30, videoBitrateBps: 3_000_000),
            sourceHeight: sourceHeight, eligibility: eligibility, showOnMonitor: true, phase: phase)
    }

    // MARK: Eligibility

    @Test func ineligibleRouteDisablesGoLiveWithReason() {
        let control = LiveStreamControlState(phase: .idle, eligibility: .cameraWiFi, serviceName: "Service A",
            elapsedSeconds: 0)
        #expect(!control.isEnabled)
        #expect(control.title == "Go live")
        #expect(control.caption == "Camera Wi-Fi has no internet")
        #expect(control.accessibilityLabel == "Go live, unavailable")
        #expect(control.accessibilityHint == LiveStreamEligibility.cameraWiFi.reason)
        #expect(control.tap == nil)
        #expect(Self.settings(eligibility: .cameraWiFi).eligibilityNote == LiveStreamEligibility.cameraWiFi.reason)
    }

    @Test func everyAllowedRouteMayGoLiveAndNoCameraMayNot() {
        #expect(LiveStreamEligibility.allowed.allowsGoLive)
        #expect(LiveStreamEligibility.allowed.reason == nil)
        #expect(!LiveStreamEligibility.noCamera.allowsGoLive)
        #expect(LiveStreamEligibility.noCamera.reason == "Connect a camera to go live.")
        let control = LiveStreamControlState(phase: .idle, eligibility: .allowed, serviceName: "Service A",
            elapsedSeconds: 0)
        #expect(control.isEnabled && control.tap == .confirmStart && control.caption == nil)
        #expect(control.accessibilityHint == "Starts streaming to Service A")
    }

    // MARK: Go live control

    @Test func runningControlStopsWithOneConfirmationEvenWhenTheRouteIsBlocked() {
        let live = LiveStreamControlState(phase: .live, eligibility: .cameraWiFi, serviceName: "Service A",
            elapsedSeconds: 754)
        #expect(live.isEnabled && live.tap == .confirmStop)
        #expect(live.title == "LIVE 12:34")
        #expect(live.accessibilityLabel == "Live for 12 minutes 34 seconds")
        #expect(live.accessibilityHint == "Ends the stream")
        let reconnecting = LiveStreamControlState(phase: .reconnecting(attempt: 2), eligibility: .allowed,
            serviceName: "Service A", elapsedSeconds: 0)
        #expect(reconnecting.title == "Reconnecting" && reconnecting.tap == .confirmStop)
        #expect(reconnecting.accessibilityLabel == "Reconnecting, attempt 2")
        let connecting = LiveStreamControlState(phase: .connecting, eligibility: .allowed, serviceName: "Service A",
            elapsedSeconds: 0)
        #expect(connecting.title == "Connecting" && connecting.accessibilityLabel == "Connecting to Service A")
    }

    @Test func startConfirmationNamesServiceQualityAndAnUnencryptedServer() {
        let quality = LiveStreamQuality(width: 1280, height: 720, framesPerSecond: 30, videoBitrateBps: 3_000_000)
        #expect(LiveStreamCopy.startTitle(service: "Service A") == "Go live on Service A?")
        let secure = LiveStreamCopy.startMessage(quality: quality, encrypted: true)
        #expect(secure.hasPrefix("720p, 30 fps, 3 Mbps. "))
        #expect(!secure.contains("Not encrypted"))
        #expect(LiveStreamCopy.startMessage(quality: quality, encrypted: false)
            .hasSuffix("\n\nNot encrypted: the stream and its key travel in the clear."))
        #expect(LiveStreamCopy.stopTitle == "End the stream?")
    }

    // MARK: Settings card

    @Test func keyFieldNeverShowsTheKey() {
        // The state carries no key text at all: only whether one is saved.
        let saved = Self.settings(key: .saved)
        #expect(saved.keyValueText == "Saved")
        #expect(saved.offersKeyEntry == false && saved.offersKeyRemoval)
        let absent = Self.settings(key: .absent)
        #expect(absent.offersKeyEntry && !absent.offersKeyRemoval)
        #expect(absent.keyValueText == nil)
    }

    @Test func lockedKeychainOffersNeitherSaveNorRemove() {
        let locked = Self.settings(key: .unavailable)
        #expect(!locked.offersKeyEntry && !locked.offersKeyRemoval)
        #expect(locked.keyUnavailableNote == "Unlock this phone to read the saved key.")
    }

    @Test func qualityLineFollowsFormat() {
        #expect(LiveStreamQuality(width: 1280, height: 720, framesPerSecond: 30, videoBitrateBps: 3_000_000).line
            == "720p, 30 fps, 3 Mbps")
        #expect(LiveStreamQuality(width: 1920, height: 1080, framesPerSecond: 29.97, videoBitrateBps: 6_000_000).line
            == "1080p, 29.97 fps, 6 Mbps")
        #expect(LiveStreamQuality(width: 720, height: 1280, framesPerSecond: 25, videoBitrateBps: 3_000_000).line
            == "720p vertical, 25 fps, 3 Mbps")
        #expect(LiveStreamQuality(width: 1024, height: 576, framesPerSecond: 24, videoBitrateBps: 2_500_000).line
            == "576p, 24 fps, 2.5 Mbps")
        var none = Self.settings()
        none.quality = nil
        #expect(none.qualityLine == "Set from the camera when you go live.")
    }

    @Test func serverFieldOnlyForEntryServicesAndPlainWarningOnlyForCustom() {
        #expect(!Self.settings("a").showsServer)
        let vertical = Self.settings("v", server: "rtmp://x/app")
        #expect(vertical.showsServer && vertical.serverPlaceholder == "rtmps://")
        #expect(!vertical.showsPlainWarning)
        #expect(vertical.verticalNote?.contains("about 405 pixels wide from a 720p feed") == true)
        let custom = Self.settings("custom", server: " RTMP://push.example.com/live")
        #expect(custom.serverPlaceholder == "rtmps:// or rtmp://")
        #expect(custom.showsPlainWarning)
        #expect(custom.plainWarning.hasPrefix("Not encrypted."))
        #expect(!Self.settings("custom", server: "rtmps://push.example.com/live").showsPlainWarning)
    }

    @Test func settingsLockWhileAStreamRuns() {
        #expect(Self.settings(phase: .live).isLocked)
        #expect(Self.settings(phase: .reconnecting(attempt: 1)).isLocked)
        #expect(!Self.settings(phase: .ended(.gaveUp)).isLocked)
    }

    @Test func monitorControlAppearsWithASavedKeyOrARunningStream() {
        #expect(Self.settings(key: .saved).showsMonitorControl)
        #expect(!Self.settings(key: .absent).showsMonitorControl)
        var hidden = Self.settings(key: .saved)
        hidden.showOnMonitor = false
        #expect(!hidden.showsMonitorControl)
        hidden.phase = .live
        #expect(hidden.showsMonitorControl)
    }

    @Test func problemsReadPerService() {
        #expect(LiveStreamProblem.notRTMPS(plainAllowed: false).text == "Use the rtmps:// address the service gave you.")
        #expect(LiveStreamProblem.notRTMPS(plainAllowed: true).text == "Use an rtmps:// or rtmp:// address.")
        #expect(LiveStreamProblem.emptyKey.text == "Paste the stream key.")
    }

    // MARK: Status readout

    @Test func statusReadoutAnnouncesHealth() {
        let status = LiveStreamStatusState(phase: .live, elapsedSeconds: 3_723, sentBitrateBps: 3_100_000,
            droppedGroups: 2, health: .congested)
        #expect(status.elapsedText == "1:02:03")
        #expect(status.bitrateText == "3.1 Mbps")
        #expect(status.droppedText == "Dropped 2")
        #expect(status.healthText == "Slow network")
        #expect(status.accessibilityLabel
            == "Streaming for 1 hour 2 minutes 3 seconds. Sending 3.1 megabits per second. 2 dropped. Connection slow.")
        let low = LiveStreamStatusState(phase: .live, elapsedSeconds: 61, sentBitrateBps: 850_000, droppedGroups: 0,
            health: .good)
        #expect(low.elapsedText == "1:01" && low.bitrateText == "850 kbps")
        #expect(low.accessibilityLabel
            == "Streaming for 1 minute 1 second. Sending 850 kilobits per second. 0 dropped. Connection good.")
    }

    @Test func endsExplainThemselvesAndOnlyBackgroundOffersRestart() {
        #expect(LiveStreamEnd.stopped.notice == nil)
        #expect(LiveStreamEnd.refused(reason: "Bad key").notice
            == "The service refused the stream: Bad key. Check the stream key and server.")
        #expect(LiveStreamEnd.unreachable.notice?.hasPrefix("Could not reach the streaming server.") == true)
        #expect(LiveStreamEnd.background.offersRestart)
        #expect(!LiveStreamEnd.gaveUp.offersRestart)
        #expect(LiveStreamWarning.hot.text == "The phone is hot. The stream continues; give it air or shade.")
    }

    @Test func appPillReadsLikeTheRunningControlAndOnlyStops() {
        let live = LiveStreamPillState(phase: .live, serviceName: "Service A", elapsedSeconds: 754)
        #expect(live.title == "LIVE 12:34")
        #expect(live.accessibilityLabel == "Live on Service A for 12 minutes 34 seconds")
        #expect(live.stopTitle == "Stop")
        #expect(live.stopAccessibilityLabel == "Stop the stream to Service A")
        #expect(live.tone == .live)
        let connecting = LiveStreamPillState(phase: .connecting, serviceName: "Service A", elapsedSeconds: 0)
        #expect(connecting.title == "Connecting" && connecting.tone == .warning)
        #expect(connecting.accessibilityLabel == "Connecting to Service A")
        let retry = LiveStreamPillState(phase: .reconnecting(attempt: 2), serviceName: "Service A", elapsedSeconds: 9)
        #expect(retry.title == "Reconnecting" && retry.accessibilityLabel == "Reconnecting to Service A, attempt 2")
    }

    @Test func upscaledQualityLineSaysUpscaled() {
        let upscaled = LiveStreamQuality(width: 1920, height: 1080, framesPerSecond: 30, videoBitrateBps: 6_000_000,
            kind: .upscaled)
        #expect(upscaled.line == "1080p upscaled, 30 fps, 6 Mbps")
        let vertical = LiveStreamQuality(width: 1080, height: 1920, framesPerSecond: 30, videoBitrateBps: 6_000_000,
            kind: .upscaled)
        #expect(vertical.line == "1080p vertical upscaled, 30 fps, 6 Mbps")
        #expect(LiveStreamCopy.startMessage(quality: upscaled, encrypted: true).hasPrefix("1080p upscaled, 30 fps"))
        let source = LiveStreamQuality(width: 1920, height: 1080, framesPerSecond: 30, videoBitrateBps: 6_000_000)
        #expect(source.line == "1080p, 30 fps, 6 Mbps")
    }

    @Test func qualityPickerShowsOnlyWithChoices() {
        let feed = LiveStreamQualityOption(id: "cameraFeed", title: LiveStreamCopy.qualityCameraFeed)
        let upscaled = LiveStreamQualityOption(id: "upscaled1080p", title: LiveStreamCopy.qualityUpscaled,
            detail: LiveStreamCopy.qualityUpscaledDetail)
        var state = Self.settings()
        #expect(!state.showsQualityPicker)
        state.qualityOptions = [feed]
        #expect(!state.showsQualityPicker)
        state.qualityOptions = [feed, upscaled]
        #expect(state.showsQualityPicker)
        #expect(state.qualityDetail == nil)
        state.selectedQualityID = "upscaled1080p"
        #expect(state.selectedQuality?.title == "1080p upscaled")
        #expect(state.qualityDetail == "The camera feed scaled up to 1080p, with your LUT.")
        let unavailable = LiveStreamQualityOption(id: "x", title: "X", unavailableReason: "Not now.")
        #expect(!unavailable.isEnabled && feed.isEnabled)
        state.qualityOptions = [feed, unavailable]
        state.selectedQualityID = "x"
        #expect(state.qualityDetail == "Not now.")
    }
}
