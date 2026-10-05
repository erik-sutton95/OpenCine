import Foundation
import OpenCineDJI

/// Actual native control source; absent transport remains absent.
public struct DjiAppleSettingsBinding: Equatable, Sendable {
    public var endpoint: ObjectIdentifier?
    public var controlGeneration: Int

    public init(endpoint: ObjectIdentifier? = nil, controlGeneration: Int = 0) {
        self.endpoint = endpoint
        self.controlGeneration = controlGeneration
    }
}

/// Captured existing audio facts, including unknown raw/decoded values.
public struct DjiAppleAudioDSPFacts: Equatable, Sendable {
    public var blob: [UInt8]?
    public var at2: AudioDspAt2?
    public var wind: WindNoiseReduction?
    public var directional: DirectionalAudio?

    public init(
        blob: [UInt8]? = nil, at2: AudioDspAt2? = nil,
        wind: WindNoiseReduction? = nil, directional: DirectionalAudio? = nil
    ) {
        self.blob = blob
        self.at2 = at2
        self.wind = wind
        self.directional = directional
    }

    fileprivate func replacingBlob(_ blob: [UInt8]) -> Self {
        var status = CameraStatus()
        status.audioDspBlob = blob
        status.audioDspAt2 = at2
        status.windNR = wind
        status.directionalAudio = directional
        if blob.count > 2 {
            AudioDspBlob.applyByte2(blob[2], to: &status)
        } else {
            status.audioDspAt2 = AudioDspBlob.at2(blob)
        }
        return .init(
            blob: blob, at2: status.audioDspAt2,
            wind: status.windNR, directional: status.directionalAudio)
    }
}

/// Serialized GET/SET workflows over the existing native request/response primitive.
/// Optimistic editor pins, native presentation and diagnostics remain host policy.
@MainActor public final class DjiAppleCameraSettings {
    @TaskLocal private static var admittedGeneration: Int?
    public static var requestControlGeneration: Int? { admittedGeneration }

    public struct Authority {
        fileprivate var generation: UInt64
        fileprivate var binding: DjiAppleSettingsBinding
    }

    public enum Event {
        case channelCompleted(AudioChannel, previous: AudioChannel?, success: Bool, Authority)
        case vocalCompleted(VocalBoost, previous: VocalBoost?, success: Bool, Authority)
        case focusPreparing(Authority)
        case focusCompleted(
            FocusTrackMode, previous: FocusTrackMode?, pinID: UUID, success: Bool, Authority)
        case missingDSP(name: String, Authority)
        case dspPrepared(DjiAppleAudioDSPFacts, Authority)
        case dspRejected(DjiAppleAudioDSPFacts, Authority)
        case dspCompleted(name: String, success: Bool, Authority)
        case glamourPrepared([UInt8], Authority)
        case glamourRejected([UInt8]?, Authority)
    }

    private enum Work {
        case channel(AudioChannel, AudioChannel?)
        case vocal(VocalBoost, VocalBoost?)
        case wind(WindNoiseReduction)
        case directional(DirectionalAudio)
        case focusTrack(FocusTrackMode, FocusTrackMode?, UUID)
        case audioRefresh
        case focusRefresh
        case isoLimitRefresh
        case clearGlamour
    }

    private let binding: () -> DjiAppleSettingsBinding
    private let request: @MainActor (Duml.Frame, String) async -> Bool
    private let audio: () -> DjiAppleAudioDSPFacts
    private let glamour: () -> [UInt8]?
    private let event: (Event) -> Void
    private var tail: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(
        binding: @escaping () -> DjiAppleSettingsBinding,
        request: @escaping @MainActor (Duml.Frame, String) async -> Bool,
        audio: @escaping () -> DjiAppleAudioDSPFacts,
        glamour: @escaping () -> [UInt8]?, event: @escaping (Event) -> Void = { _ in }
    ) {
        self.binding = binding
        self.request = request
        self.audio = audio
        self.glamour = glamour
        self.event = event
    }

    public func setChannel(_ value: AudioChannel, previous: AudioChannel?) {
        enqueue(.channel(value, previous))
    }
    public func setVocalBoost(_ value: VocalBoost, previous: VocalBoost?) {
        enqueue(.vocal(value, previous))
    }
    public func setWind(_ value: WindNoiseReduction) { enqueue(.wind(value)) }
    public func setDirectional(_ value: DirectionalAudio) { enqueue(.directional(value)) }
    public func setFocusTrack(_ value: FocusTrackMode, previous: FocusTrackMode?, pinID: UUID) {
        enqueue(.focusTrack(value, previous, pinID))
    }
    public func refreshAudio() { enqueue(.audioRefresh) }
    public func refreshFocus() { enqueue(.focusRefresh) }
    public func refreshIsoLimit() { enqueue(.isoLimitRefresh) }
    public func clearGlamour() { enqueue(.clearGlamour) }

    /// Captures the current tail exactly as the original caller's await did.
    public func waitForPending() async { await tail?.value }

    /// Local retirement never transmits or cancels another transport owner.
    public func retire() {
        generation &+= 1
        let previous = tail
        tail = nil
        previous?.cancel()
    }

    public func admits(_ authority: Authority) -> Bool {
        generation == authority.generation && !Task.isCancelled && binding() == authority.binding
    }

    private func enqueue(_ work: Work) {
        let previous = tail
        let authority = Authority(generation: generation, binding: binding())
        tail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.admits(authority) else { return }
            await Self.$admittedGeneration.withValue(authority.binding.controlGeneration) {
                await self.execute(work, authority: authority)
            }
        }
    }

    private func execute(_ work: Work, authority: Authority) async {
        switch work {
        case .channel(let value, let previous):
            let ok = await request(Commands.setAudioChannel(value), "Audio \(value.label)")
            guard admits(authority) else { return }
            event(.channelCompleted(value, previous: previous, success: ok, authority))
        case .vocal(let value, let previous):
            let ok = await request(Commands.setVocalBoost(value), "Vocal \(value.label)")
            guard admits(authority) else { return }
            event(.vocalCompleted(value, previous: previous, success: ok, authority))
        case .wind(let value):
            await patchDSP(name: "Wind \(value.label)", authority: authority) {
                AudioDspBlob.patchWind($0, value)
            }
        case .directional(let value):
            await patchDSP(name: "Dir \(value.label)", authority: authority) {
                AudioDspBlob.patchDirectional($0, value)
            }
        case .focusTrack(let value, let previous, let pinID):
            event(.focusPreparing(authority))
            guard admits(authority) else { return }
            let ok = await request(Commands.setFocusTrack(value), "AF-C \(value.label)")
            guard admits(authority) else { return }
            event(.focusCompleted(value, previous: previous, pinID: pinID, success: ok, authority))
        case .audioRefresh:
            for (frame, name) in zip(
                Commands.audioStateGets, ["Audio ch GET", "Vocal GET", "AudioDSP GET"])
            {
                guard admits(authority) else { return }
                _ = await request(frame, name)
            }
        case .focusRefresh:
            _ = await request(Commands.getFocusTrack(), "Focus track GET")
        case .isoLimitRefresh:
            _ = await request(Commands.getIsoLimit(), "ISO limit GET")
        case .clearGlamour:
            let ok = await request(Commands.getGlamour(), "Glamour GET")
            guard admits(authority), ok, let blob = glamour(), GlamourEffect.isEnabled(blob),
                let off = GlamourEffect.disabled(blob)
            else { return }
            let previous = glamour()
            event(.glamourPrepared(off, authority))
            guard admits(authority) else { return }
            let setOK = await request(Commands.setGlamour(off), "Glamour off")
            guard admits(authority) else { return }
            if !setOK { event(.glamourRejected(previous, authority)) }
        }
    }

    private func patchDSP(name: String, authority: Authority, patch: ([UInt8]) -> [UInt8]) async {
        let got = await request(Commands.audioDspGet(), "AudioDSP GET")
        guard admits(authority) else { return }
        guard got, let blob = audio().blob, blob.count > 2 else {
            event(.missingDSP(name: name, authority))
            return
        }
        let next = patch(blob)
        let previous = audio()
        event(.dspPrepared(previous.replacingBlob(next), authority))
        guard admits(authority) else { return }
        let ok = await request(Commands.audioDspSet(next), name)
        guard admits(authority) else { return }
        if !ok {
            event(.dspRejected(previous, authority))
            guard admits(authority) else { return }
        }
        event(.dspCompleted(name: name, success: ok, authority))
    }
}
