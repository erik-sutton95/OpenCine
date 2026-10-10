import Foundation
import OpenCineDJI
import OpenCineDJIApple
import Testing

/// SIMULATED actual request gate and captured host facts; no sleeps or camera transport.
@Suite @MainActor
struct DJIAppleCameraSettingsTests {
    private final class Endpoint {}

    @MainActor private final class Peer {
        let first = Endpoint()
        let second = Endpoint()
        var binding: DjiAppleSettingsBinding!
        var audio = DjiAppleAudioDSPFacts()
        var glamour: [UInt8]?
        var requests: [(Duml.Frame, String, Int?)] = []
        var gates: [CheckedContinuation<Bool, Never>] = []
        var events: [DjiAppleCameraSettings.Event] = []
        var observer: ((DjiAppleCameraSettings.Event) -> Void)?
        lazy var owner = DjiAppleCameraSettings(
            binding: { [unowned self] in binding },
            request: { [unowned self] frame, name in
                requests.append((frame, name, DjiAppleCameraSettings.requestControlGeneration))
                return await withCheckedContinuation { gates.append($0) }
            }, audio: { [unowned self] in audio }, glamour: { [unowned self] in glamour },
            event: { [unowned self] event in
                events.append(event)
                if case .dspPrepared(let facts, _) = event { audio = facts }
                if case .dspRejected(let facts, _) = event { audio = facts }
                if case .glamourPrepared(let blob, _) = event { glamour = blob }
                if case .glamourRejected(let blob, _) = event { glamour = blob }
                observer?(event)
            })

        init() { binding = .init(endpoint: ObjectIdentifier(first), controlGeneration: 1) }
        func settle() async { for _ in 0..<50 { await Task.yield() } }
        func reply(_ success: Bool) async {
            #expect(!gates.isEmpty)
            guard !gates.isEmpty else { return }
            gates.removeFirst().resume(returning: success)
            await settle()
        }
        func finish() async {
            owner.retire()
            while !gates.isEmpty { await reply(false) }
            await settle()
        }
    }

    @Test func actualChannelThenVocalUsesOneFIFORequestChainAndCapturedGeneration() async {
        let p = Peer()
        p.owner.setChannel(.mono, previous: .stereo)
        p.owner.setVocalBoost(.on, previous: .off)
        await p.settle()
        #expect(p.requests.count == 1)
        #expect(p.requests[0].0 == Commands.setAudioChannel(.mono))
        #expect(p.requests[0].1 == "Audio Mono" && p.requests[0].2 == 1)
        await p.reply(true)
        #expect(p.requests.count == 2 && p.requests[1].0 == Commands.setVocalBoost(.on))
        #expect(p.requests[1].1 == "Vocal On" && p.requests[1].2 == 1)
        await p.reply(false)
        #expect(p.events.count == 2)
        if case .vocalCompleted(.on, .off, false, _) = p.events.last {
        } else {
            Issue.record("missing original rejection facts")
        }
        await p.finish()
    }

    @Test func mandatoryDSPGetPatchesOnlyOriginalByteAndFailureRestoresCapturedUnknownFacts() async
    {
        let p = Peer()
        let blob = Array(UInt8(0)..<UInt8(26))
        p.owner.setDirectional(.front)
        await p.settle()
        #expect(p.requests[0].0 == Commands.audioDspGet())
        p.audio = .init(blob: blob, at2: .unknown(2), wind: nil, directional: nil)
        let previous = p.audio
        await p.reply(true)
        let patched = AudioDspBlob.patchDirectional(blob, .front)
        #expect(p.requests[1].0 == Commands.audioDspSet(patched))
        #expect(p.requests[1].1 == "Dir Front")
        #expect(p.audio.blob == patched && p.audio.wind == .on && p.audio.directional == .front)
        #expect(
            Array(patched[..<2]) == Array(blob[..<2]) && Array(patched[3...]) == Array(blob[3...]))
        await p.reply(false)
        #expect(p.audio == previous)
        await p.finish()
    }

    @Test func failedOrAbsentGETNeverManufacturesDSPOrSendsSET() async {
        for got in [false, true] {
            let p = Peer()
            p.owner.setWind(.on)
            await p.settle()
            await p.reply(got)
            #expect(p.requests.count == 1 && p.audio.blob == nil)
            if case .missingDSP("Wind On", _) = p.events.last {
            } else {
                Issue.record("missing original no-blob outcome")
            }
            await p.finish()
        }
    }

    @Test func refreshKeepsExactThreeGETOrderAndDoesNotInventState() async {
        let p = Peer()
        p.owner.refreshAudio()
        await p.settle()
        for _ in 0..<3 { await p.reply(false) }
        #expect(p.requests.map { $0.0 } == Commands.audioStateGets)
        #expect(p.requests.map { $0.1 } == ["Audio ch GET", "Vocal GET", "AudioDSP GET"])
        #expect(p.events.isEmpty && p.audio == .init())
        await p.finish()
    }

    @Test func replacedEndpointRejectsLateDSPContinuationAndAllowsSuccessorRequest() async {
        let p = Peer()
        p.owner.setWind(.on)
        await p.settle()
        p.binding = .init(endpoint: ObjectIdentifier(p.second), controlGeneration: 2)
        p.audio = .init(blob: Array(repeating: 0x18, count: 26), at2: .wind(.off), wind: .off)
        p.owner.setChannel(.spatial, previous: nil)
        await p.reply(true)
        #expect(p.events.isEmpty)
        #expect(p.requests.count == 2 && p.requests[1].0 == Commands.setAudioChannel(.spatial))
        #expect(p.requests[1].2 == 2)
        await p.reply(true)
        #expect(p.events.count == 1)
        await p.finish()
    }

    @Test func synchronousPreparedReplacementCannotSendOutgoingDSPToSuccessor() async {
        let p = Peer()
        p.audio = .init(blob: Array(repeating: 0x18, count: 26), at2: .wind(.off), wind: .off)
        p.observer = { event in
            guard case .dspPrepared(_, let authority) = event else { return }
            #expect(p.owner.admits(authority))
            p.binding = .init(endpoint: ObjectIdentifier(p.second), controlGeneration: 2)
            #expect(!p.owner.admits(authority))
        }
        p.owner.setWind(.on)
        await p.settle()
        await p.reply(true)
        #expect(
            p.requests.count == 1
                && !p.events.contains {
                    if case .dspCompleted = $0 { return true }
                    return false
                })
        await p.finish()
    }

    @Test func retirementRejectsOldFailureAndDoesNotBlockCurrentTail() async {
        let p = Peer()
        p.owner.setChannel(.mono, previous: .stereo)
        await p.settle()
        p.owner.retire()
        p.owner.setVocalBoost(.on, previous: nil)
        await p.settle()
        #expect(p.requests.count == 2)
        await p.reply(false)
        #expect(p.events.isEmpty)
        await p.reply(true)
        #expect(p.events.count == 1)
        await p.finish()
    }

    @Test func focusTrackKeepsActualPinIdentityAndRefreshSharesQueue() async {
        let p = Peer()
        let pin = UUID()
        p.owner.setFocusTrack(.default, previous: nil, pinID: pin)
        p.owner.refreshFocus()
        p.owner.refreshIsoLimit()
        await p.settle()
        #expect(p.requests[0].0 == Commands.setFocusTrack(.default))
        await p.reply(false)
        #expect(p.events.count == 2)
        if case .focusCompleted(.default, nil, let captured, false, _) = p.events.last {
            #expect(captured == pin)
        } else {
            Issue.record("missing pin-qualified outcome")
        }
        #expect(p.requests[1].0 == Commands.getFocusTrack())
        await p.reply(true)
        #expect(p.requests[2].0 == Commands.getIsoLimit())
        await p.reply(true)
        await p.finish()
    }

    @Test func glamourDisablesOnlyMasterByteAndFailedSETKeepsOriginalBlob() async {
        let p = Peer()
        let original = Array(UInt8(0)..<UInt8(62))
        p.glamour = original
        p.owner.clearGlamour()
        await p.settle()
        #expect(p.requests[0].0 == Commands.getGlamour())
        await p.reply(true)
        let disabled = GlamourEffect.disabled(original)!
        #expect(p.requests[1].0 == Commands.setGlamour(disabled))
        #expect(p.requests[1].1 == "Glamour off" && disabled[5] == 0)
        #expect(
            Array(disabled[..<5]) == Array(original[..<5])
                && Array(disabled[6...]) == Array(original[6...]))
        #expect(p.glamour == disabled)
        await p.reply(false)
        #expect(p.glamour == original)
        await p.finish()
    }

    @Test func absentDisabledOrIncompleteGlamourNeverManufacturesSETBytes() async {
        let sources: [[UInt8]?] = [
            nil, Array(repeating: 0, count: 62), Array(repeating: 1, count: 61),
        ]
        for source in sources {
            let p = Peer()
            p.glamour = source
            p.owner.clearGlamour()
            await p.settle()
            await p.reply(true)
            #expect(p.requests.count == 1 && p.events.isEmpty && p.glamour == source)
            await p.finish()
        }
    }

}
