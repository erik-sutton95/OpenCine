import Foundation
import Testing

import OpenCineRelay

@Suite("Watch relay wire protocol")
struct WatchRelayProtocolTests {
    private func sampleState() -> WatchRelayState {
        WatchRelayState(
            isRecording: true,
            timecode: "01:02:03",
            media: "12 GB · 47%",
            cameraBatteryPercent: 80,
            cameraName: "Osmo Pocket 4",
            connection: .connected,
            feedLive: true)
    }

    @Test("A ticking timecode is not a state change")
    func liveReadoutsDoNotCountAsStateChange() {
        let state = sampleState()
        let ticked = WatchRelayState(
            isRecording: state.isRecording,
            timecode: "01:02:04",
            media: state.media,
            cameraBatteryPercent: state.cameraBatteryPercent,
            cameraName: state.cameraName,
            connection: state.connection,
            feedLive: state.feedLive)
        #expect(ticked != state)
        #expect(ticked.matchesIgnoringLiveReadouts(state))
    }

    @Test("A stills-mode flip is a state change")
    func modeFlipCountsAsStateChange() {
        let state = sampleState()
        let photography = WatchRelayState(
            isRecording: state.isRecording,
            timecode: state.timecode,
            media: state.media,
            cameraBatteryPercent: state.cameraBatteryPercent,
            cameraName: state.cameraName,
            connection: state.connection,
            feedLive: state.feedLive,
            isPhotography: true)
        #expect(!photography.matchesIgnoringLiveReadouts(state))
    }

    @Test(
        "Every payload round-trips through its envelope",
        arguments: [WatchRelayProtocol.Kind.state, .frame, .command, .result])
    func envelopeRoundTrips(kind: WatchRelayProtocol.Kind) throws {
        switch kind {
        case .state:
            try expectRoundTrip(kind, sampleState())
        case .frame:
            try expectRoundTrip(
                kind,
                WatchRelayFrame(
                    jpeg: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]),
                    timecode: "12:34:56",
                    isRecording: true))
        case .command:
            try expectRoundTrip(kind, WatchRelayCommand.toggleRecord)
        case .result:
            try expectRoundTrip(
                kind,
                WatchCommandResult(accepted: false, isRecording: true, error: WatchRelayCopy.busy))
        }
    }

    private func expectRoundTrip<Payload: Codable & Equatable>(
        _ kind: WatchRelayProtocol.Kind, _ payload: Payload
    ) throws {
        let envelope = try WatchRelayEnvelope.encode(kind: kind, payload: payload)
        #expect(try WatchRelayEnvelope.kind(of: envelope) == kind)
        #expect(try WatchRelayEnvelope.decode(Payload.self, from: envelope) == payload)
    }

    @Test("State without photography keys still decodes")
    func stateWithoutPhotographyKeysDecodes() throws {
        let json = """
            {"isRecording":false,"timecode":"--:--:--","media":"\u{2014}","cameraBatteryPercent":-1,"cameraName":"","connection":"noCamera","feedLive":false}
            """
        var envelope = Data([WatchRelayProtocol.Kind.state.rawValue])
        envelope.append(Data(json.utf8))
        let decoded = try WatchRelayEnvelope.decode(WatchRelayState.self, from: envelope)
        #expect(decoded.isPhotography == false)
        #expect(decoded.feedAspectRatio == 16.0 / 9.0)
        #expect(decoded.connection == .noCamera)
    }

    @Test("Empty envelope reports an empty error")
    func emptyEnvelopeThrows() {
        #expect(throws: WatchRelayEnvelopeError.empty) {
            try WatchRelayEnvelope.kind(of: Data())
        }
    }

    @Test("Unknown kind byte is rejected")
    func unknownKindThrows() {
        #expect(throws: WatchRelayEnvelopeError.unknownKind(0x99)) {
            try WatchRelayEnvelope.kind(of: Data([0x99, 0x00]))
        }
    }

    @Test("Storage label prefers GB and percent, then remaining minutes")
    // Keep the retained legacy formatter's original compatibility assertions under WAE.
    @available(*, deprecated, message: "Exercises the retained legacy WatchRelayMedia formatter")
    func storageLabelMatchesPhoneHUD() {
        #expect(
            WatchRelayMedia.label(
                storageFreeMb: 12_288, storageTotalMb: 26_624,
                sdFreeMb: 0, sdTotalMb: 0, recordRemainingSec: 600)
                == "12 GB · 46%")
        #expect(
            WatchRelayMedia.label(
                storageFreeMb: 0, storageTotalMb: 0,
                sdFreeMb: 0, sdTotalMb: 0, recordRemainingSec: 180)
                == "3 Min")
        #expect(
            WatchRelayMedia.label(
                storageFreeMb: 0, storageTotalMb: 0,
                sdFreeMb: 0, sdTotalMb: 0, recordRemainingSec: 0)
                == "\u{2014}")
    }

    /// What an app's snapshot gives while the phone is not live (pinned per app).
    private func noCameraState() -> WatchRelayState {
        WatchRelayState(
            isRecording: false,
            timecode: "--:--:--",
            media: "--",
            cameraBatteryPercent: 0,
            cameraName: "",
            connection: .noCamera,
            feedLive: false)
    }

    // Moved from both iOS apps' WatchRelaySnapshotTests; their snapshot cases stay with each app.
    @Test("Wrist-down does not cover a live tally with open-on-iPhone")
    func placeholderKeepsLastTallyWhenUnreachable() {
        let live = sampleState()
        #expect(
            WatchMonitorPlaceholder.resolve(
                isReachable: false, state: live, hasFeed: true) == .none)
        #expect(
            WatchMonitorPlaceholder.resolve(
                isReachable: false, state: nil, hasFeed: false) == .openOnIPhone)
        #expect(
            WatchMonitorPlaceholder.resolve(
                isReachable: true, state: nil, hasFeed: false) == .none)
        let noCamera = noCameraState()
        #expect(
            WatchMonitorPlaceholder.resolve(
                isReachable: true, state: noCamera, hasFeed: false) == .noCamera)
    }

    @Test("Disconnect labels a retained picture, even while the wrist is down")
    func disconnectedSnapshotOverlaysOldFrame() {
        let noCamera = noCameraState()
        for reachable in [true, false] {
            #expect(
                WatchMonitorPlaceholder.resolve(
                    isReachable: reachable, state: noCamera, hasFeed: true) == .noCamera)
        }
    }

    @Test("Every app's wrist placeholder names that app the same way")
    func openOnIPhoneNamesTheApp() {
        #expect(WatchRelayCopy.openOnIPhone(appName: "OpenPocketCine") == "Open OpenPocketCine on iPhone")
        #expect(WatchRelayCopy.openOnIPhone(appName: "OpenInstaCine") == "Open OpenInstaCine on iPhone")
        #expect(
            WatchMonitorPlaceholder.openOnIPhone.copy(
                openOnIPhone: WatchRelayCopy.openOnIPhone(appName: "OpenZCine"))
                == "Open OpenZCine on iPhone")
    }

    @Test("Operator copy never names a sister app")
    func operatorCopyIsPocketFacing() {
        let facing = [
            WatchRelayCopy.noCamera,
            WatchRelayCopy.waitingLive,
            WatchRelayCopy.connectFirst,
            WatchRelayCopy.switchToVideo,
            WatchRelayCopy.switchToPhoto,
            WatchRelayCopy.busy,
            WatchRelayCopy.cameraChanged,
        ]
        for text in facing {
            #expect(!text.localizedCaseInsensitiveContains("OpenZCine"))
            #expect(!text.localizedCaseInsensitiveContains("Nikon"))
        }
    }
}
