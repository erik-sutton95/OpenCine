#if os(iOS)
import AVFAudio
import CoreMedia
import Foundation
import Observation
import OpenCineAppKit
import OpenCineCore
import os
import Speech
import SwiftUI

@MainActor
@Observable
public final class MonitorVoiceControl {
    public typealias Execute = @MainActor (VoiceCommand, VoiceCommandPermit, VoiceControlTarget) async -> String

    private enum Stage {
        case model
        case microphone
        case recognizer

        var failureMessage: String {
            switch self {
            case .model: "Couldn’t download the English speech model. Connect to the internet and try again."
            case .microphone: "Couldn’t start the microphone. Check your audio input and try again."
            case .recognizer: "The speech recognizer stopped. Tap the mic to try again."
            }
        }
    }

    public private(set) var message: String?
    public private(set) var recognizedPhrase: String?
    public private(set) var listening = false
    public private(set) var armed = false
    public let preferences = MonitorVoicePreferences()
    @ObservationIgnored private var lifetime: VoiceCommandPermit?
    @ObservationIgnored private var speechTask: Task<Void, Never>?
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    @ObservationIgnored private var phraseTask: Task<Void, Never>?
    @ObservationIgnored private var recognitionFeedbackTask: Task<Void, Never>?
    @ObservationIgnored private var confirmationFeedbackTask: Task<Void, Never>?
    @ObservationIgnored private var stopInput: (() -> Void)?
    private let feedbackClock: HostClock

    public convenience init() {
        self.init(feedbackClock: .live)
    }

    init(feedbackClock: HostClock) {
        self.feedbackClock = feedbackClock
    }

    public static var supported: Bool {
        if #available(iOS 26, *) { SpeechTranscriber.isAvailable } else { false }
    }

    public func toggle(target: VoiceControlTarget, execute: @escaping Execute) {
        toggle(target: target, supportsLens: false, execute: execute)
    }

    public func toggle(target: VoiceControlTarget, supportsLens: Bool, execute: @escaping Execute) {
        if armed {
            disarm()
            return
        }
        guard #available(iOS 26, *), Self.supported else { return }
        let arm = VoiceCommandPermit(while: { true })
        lifetime = arm
        armed = true
        message = "Preparing voice control…"
        speechTask = Task { [weak self] in
            guard let self else { return }
            var stage = Stage.model
            do {
                try await recognize(arm: arm, stage: &stage) { command, phrase in
                    guard self.preferences.allows(command, supportsLens: supportsLens) else {
                        return "This voice command is disabled or unavailable."
                    }
                    self.showRecognizedPhrase(phrase)
                    return await execute(command, arm, target)
                }
                if arm.isCurrent { disarm(message: "Voice recognition ended.") }
            } catch {
                guard arm.isCurrent else { return }
                disarm(message: stage.failureMessage)
            }
        }
    }

    public func disarm() { disarm(message: nil) }

    private func disarm(message: String?) {
        lifetime?.revoke()
        lifetime = nil
        speechTask?.cancel()
        speechTask = nil
        commandTask?.cancel()
        commandTask = nil
        phraseTask?.cancel()
        phraseTask = nil
        recognitionFeedbackTask?.cancel()
        recognitionFeedbackTask = nil
        cancelConfirmationFeedback()
        stopInput?()
        stopInput = nil
        armed = false
        listening = false
        recognizedPhrase = nil
        self.message = message
    }

    func showRecognizedPhrase(_ phrase: String) {
        recognitionFeedbackTask?.cancel()
        cancelConfirmationFeedback()
        message = nil
        recognizedPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        recognitionFeedbackTask = Task { [weak self, feedbackClock] in
            do { try await feedbackClock.sleep(.seconds(1)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.recognizedPhrase = nil
            self?.recognitionFeedbackTask = nil
        }
    }

    func showCommandResult(_ result: String, for command: VoiceCommand) {
        cancelConfirmationFeedback()
        message = result
        guard command.isConfirmation(result) else { return }
        confirmationFeedbackTask = Task { [weak self, feedbackClock] in
            do { try await feedbackClock.sleep(.seconds(2)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.message = nil
            self?.confirmationFeedbackTask = nil
        }
    }

    private func cancelConfirmationFeedback() {
        confirmationFeedbackTask?.cancel()
        confirmationFeedbackTask = nil
    }

    @available(iOS 26, *)
    private func recognize(
        arm: VoiceCommandPermit, stage: inout Stage,
        execute: @escaping @MainActor (VoiceCommand, String) async -> String
    ) async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            if arm.isCurrent { disarm(message: "Allow microphone access in Settings to use voice control.") }
            return
        }
        try Task.checkCancellation()
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            if arm.isCurrent { disarm(message: "English speech recognition is unavailable on this iPhone.") }
            return
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            try Task.checkCancellation()
            message = "Downloading the English speech model…"
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await installation.downloadAndInstall()
            }
            guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
                if arm.isCurrent { disarm(message: Stage.model.failureMessage) }
                return
            }
        }
        try Task.checkCancellation()
        guard UIApplication.shared.applicationState == .active else { return }
        stage = .microphone
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try audioSession.setActive(true)
        stopInput = { try? audioSession.setActive(false, options: .notifyOthersOnDeactivation) }

        let engine = AVAudioEngine()
        let node = engine.inputNode
        let natural = node.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, natural.channelCount > 0,
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber], considering: natural),
            let converter = AVAudioConverter(from: natural, to: format)
        else {
            if arm.isCurrent { disarm(message: "No compatible microphone input is available.") }
            return
        }
        try Task.checkCancellation()
        stage = .recognizer
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        defer { Task { await analyzer.cancelAndFinishNow() } }
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        let (input, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingOldest(32))
        defer { continuation.finish() }
        try await analyzer.start(inputSequence: input)
        try Task.checkCancellation()
        stage = .microphone
        guard node.outputFormat(forBus: 0) == natural else {
            disarm(message: "The microphone input changed. Tap the mic to try again.")
            return
        }
        let microphone = MonitorVoiceMicrophoneInput(converter: converter, output: format, continuation: continuation) {
            guard arm.isCurrent else { return }
            arm.revoke()
            Task { @MainActor [weak self] in
                guard self?.lifetime === arm else { return }
                self?.disarm(message: "Microphone input was interrupted.")
            }
        }
        // AVAudioEngine invokes this on its audio thread. Prevent the callback from inheriting
        // the monitor's main actor and trapping on its first buffer.
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buffer, _ in
            microphone.append(buffer)
        }
        stopInput = {
            node.removeTap(onBus: 0)
            engine.stop()
            continuation.finish()
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        }
        engine.prepare()
        let start = ProcessInfo.processInfo.systemUptime
        try engine.start()
        try Task.checkCancellation()
        stage = .recognizer
        listening = true
        message = nil

        var gate = VoiceUtteranceGate()
        var phrase: MonitorVoicePhrase?
        var tentative: MonitorVoicePhrase?
        for try await result in transcriber.results {
            guard arm.isCurrent, !Task.isCancelled else { return }
            let begin = result.range.start.seconds, end = result.range.end.seconds
            guard begin.isFinite, end.isFinite, end > begin else { continue }
            let segment = MonitorVoicePhrase(text: String(result.text.characters), start: begin, end: end)
            if !result.isFinal {
                tentative = segment
                if phrase?.isContinued(by: segment) == true {
                    phraseTask?.cancel()
                }
                continue
            }
            let waitForContinuation: Double
            if let previous = phrase, let joined = previous.joining(segment, dispatchPending: phraseTask != nil) {
                phrase = joined
                waitForContinuation = MonitorVoicePhrase.joinWindow
            } else {
                phrase = segment
                waitForContinuation = segment.waitForContinuation(after: tentative)
            }
            tentative = nil
            phraseTask?.cancel()
            phraseTask = nil
            // A separately finalized wake word has no command yet. Its adjacent audio
            // can still arrive later without consuming the wake word's range first.
            guard let candidate = phrase, !candidate.isWakeWord else { continue }
            phraseTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(waitForContinuation)) } catch { return }
                guard let self, arm.isCurrent, !Task.isCancelled else { return }
                self.phraseTask = nil
                let now = ProcessInfo.processInfo.systemUptime - start
                guard let command = gate.accept(candidate.text, start: candidate.start, end: candidate.end, now: now),
                    self.commandTask == nil
                else { return }
                self.commandTask = Task { [weak self] in
                    guard let self, arm.isCurrent, !Task.isCancelled else { return }
                    let result = await execute(command, candidate.text)
                    guard arm.isCurrent else { return }
                    self.showCommandResult(result, for: command)
                    self.commandTask = nil
                }
            }
        }
    }
}

struct MonitorVoicePhrase {
    static let joinWindow = 0.45

    let text: String
    let start: Double
    let end: Double

    var isWakeWord: Bool { VoiceCommand.isWakeWord(text) }

    func joining(_ segment: Self, dispatchPending: Bool) -> Self? {
        guard segment.start >= end, isContinued(by: segment), dispatchPending || isWakeWord else { return nil }
        return Self(text: text + " " + segment.text, start: start, end: segment.end)
    }

    func isContinued(by segment: Self) -> Bool {
        segment.start < end + Self.joinWindow && segment.end > end
    }

    func waitForContinuation(after tentative: Self?) -> Double {
        guard let tentative, tentative.start <= start, tentative.end >= end + Self.joinWindow,
            let command = VoiceCommand.parse(text), !command.changesSettings,
            VoiceCommand.parse(tentative.text) == command
        else { return Self.joinWindow }
        // Speech can split a sentence and publish the continuation in the next result.
        // Allow that result to arrive even when the tentative range covers the trailing audio.
        return 0.15
    }
}

/// The audio engine calls its input tap serially and the converter belongs to that tap.
@available(iOS 26, *)
final class MonitorVoiceMicrophoneInput: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let interrupted: @Sendable () -> Void

    init(converter: AVAudioConverter, output: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation, interrupted: @escaping @Sendable () -> Void
    ) {
        self.converter = converter
        self.output = output
        self.continuation = continuation
        self.interrupted = interrupted
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format == converter.inputFormat else { interrupted(); return }
        guard buffer.frameLength > 0 else { return }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate))
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
        let supplied = OSAllocatedUnfairLock(initialState: false)
        var error: NSError?
        let result = converter.convert(to: converted, error: &error) { _, status in
            let alreadyDelivered = supplied.withLock { delivered in
                defer { delivered = true }
                return delivered
            }
            status.pointee = alreadyDelivered ? .noDataNow : .haveData
            return alreadyDelivered ? nil : buffer
        }
        guard result != .error else { interrupted(); return }
        guard converted.frameLength > 0 else { return }
        // Resampling can shift frames across tap buffers. The analyzer advances its timeline
        // by each converted buffer's actual duration.
        let yielded = continuation.yield(AnalyzerInput(buffer: converted))
        if case .dropped = yielded { interrupted() }
    }
}

@MainActor
public struct MonitorVoiceTool {
    public let control: MonitorVoiceControl
    private let target: VoiceControlTarget?
    private let supportsLens: Bool
    private let execute: MonitorVoiceControl.Execute

    public init(control: MonitorVoiceControl, target: VoiceControlTarget?, supportsLens: Bool = false,
        execute: @escaping MonitorVoiceControl.Execute) {
        self.control = control; self.target = target; self.supportsLens = supportsLens; self.execute = execute
    }

    public var isAvailable: Bool {
        MonitorVoiceControl.supported && (target != nil || control.armed)
    }

    public var canToggle: Bool {
        control.armed || (target != nil && control.preferences.availableActions(supportsLens: supportsLens)
            .contains(where: control.preferences.isEnabled))
    }

    public func toggle() {
        guard canToggle else { return }
        if let target { control.toggle(target: target, supportsLens: supportsLens, execute: execute) }
        else { control.disarm() }
    }

    public var feedback: some View {
        MonitorVoiceButton(control: control, target: target, supportsLens: supportsLens,
            showsToggle: false, execute: execute)
    }
}

public struct MonitorVoiceButton: View {
    private let control: MonitorVoiceControl
    private let target: VoiceControlTarget?
    private let supportsLens: Bool
    private let showsToggle: Bool
    private let execute: MonitorVoiceControl.Execute
    @Environment(\.scenePhase) private var scenePhase

    public init(control: MonitorVoiceControl, target: VoiceControlTarget?, execute: @escaping MonitorVoiceControl.Execute) {
        self.init(control: control, target: target, supportsLens: false, execute: execute)
    }

    public init(control: MonitorVoiceControl, target: VoiceControlTarget?, supportsLens: Bool,
        execute: @escaping MonitorVoiceControl.Execute) {
        self.init(control: control, target: target, supportsLens: supportsLens, showsToggle: true, execute: execute)
    }

    init(control: MonitorVoiceControl, target: VoiceControlTarget?, supportsLens: Bool, showsToggle: Bool,
        execute: @escaping MonitorVoiceControl.Execute) {
        self.control = control
        self.target = target
        self.supportsLens = supportsLens
        self.showsToggle = showsToggle
        self.execute = execute
    }

    public var body: some View {
        if MonitorVoiceControl.supported {
            VStack(alignment: .trailing, spacing: 4) {
                if showsToggle {
                    Button {
                        if let target { control.toggle(target: target, supportsLens: supportsLens, execute: execute) }
                    } label: {
                        Image(systemName: control.armed ? "mic.fill" : "mic")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(control.listening ? Color.orange : Color.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.75), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(target == nil || scenePhase != .active ||
                        (!control.armed && !control.preferences.availableActions(supportsLens: supportsLens)
                            .contains(where: control.preferences.isEnabled)))
                    .accessibilityLabel(control.armed ? "Disarm voice control" : "Arm voice control")
                    .accessibilityIdentifier("monitor.voiceControl")
                }
                feedback
            }
            .onChange(of: target?.session) { _, _ in control.disarm() }
            .onChange(of: target?.epoch) { _, _ in control.disarm() }
            .onChange(of: supportsLens) { _, _ in control.disarm() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background || (phase == .inactive && control.listening) { control.disarm() }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
                .receive(on: DispatchQueue.main)) { _ in
                if control.listening { control.disarm() }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
                .receive(on: DispatchQueue.main)) { notification in
                let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                if control.listening, reason != AVAudioSession.RouteChangeReason.categoryChange.rawValue {
                    control.disarm()
                }
            }
            .onDisappear { control.disarm() }
        }
    }

    @ViewBuilder var feedback: some View {
        if let phrase = control.recognizedPhrase {
            statusBadge(phrase)
                .accessibilityIdentifier("monitor.voiceControl.recognizedPhrase")
        }
        if let message = control.message {
            statusBadge(message)
        }
    }

    private func statusBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.white)
            .padding(6)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 5))
            .allowsHitTesting(false)
    }
}
#endif
