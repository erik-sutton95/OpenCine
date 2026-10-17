import Foundation
import MonitorPresentation
import OpenCineCameraVocabulary

#if os(iOS)
    import OpenCineApple
    import UIKit
#endif

/// Debug-only live-feed stress seam the camera apps share. Release is a no-op. No operator chrome.
///
/// Present counters are admission, not display scanout:
/// `noteIdentityEnqueue` = AVSampleBufferDisplayLayer enqueue;
/// `noteMetalPresent` = Metal GPU completion; `notePresent()` splits by the caller's `#fileID`.
///
/// The app supplies the live camera through ``FeedStressHost`` and the reporting hook at install.
public enum FeedStressAutomation {
    private static let enabled = ProcessInfo.processInfo.environment["OPV_FEED_STRESS"] == "1"

    public static var isEnabled: Bool { enabled }

    public static var injectionDidActivate: Bool {
        #if DEBUG && os(iOS)
            return FeedStressRuntime.shared.injectionDidActivate
        #else
            return false
        #endif
    }

    /// Starts the run when `OPV_FEED_STRESS=1`. `host` returns the app's live camera when one is
    /// composed; `onInjectionActivated` runs once, off the main actor, when a fault first lands.
    public static func installIfRequested(
        host: @escaping @MainActor () -> (any FeedStressHost)?,
        onInjectionActivated: @escaping @Sendable () -> Void
    ) {
        #if DEBUG && os(iOS)
            guard enabled else { return }
            FeedStressRuntime.shared.installIfRequested(
                host: host, onInjectionActivated: onInjectionActivated)
        #endif
    }

    public static func noteSourceObserved(videoPackets: Int, accessUnits: Int) {
        #if DEBUG && os(iOS)
            guard enabled else { return }
            FeedStressRuntime.shared.noteSourceObserved(
                videoPackets: videoPackets, accessUnits: accessUnits)
        #endif
    }

    public static func noteSourceDelivered(videoPackets: Int, accessUnits: Int) {
        #if DEBUG && os(iOS)
            guard enabled else { return }
            FeedStressRuntime.shared.noteSourceDelivered(
                videoPackets: videoPackets, accessUnits: accessUnits)
        #endif
    }

    public static func noteDecodeSubmit() {
        #if DEBUG && os(iOS)
            guard enabled else { return }
            FeedStressRuntime.shared.noteDecodeSubmit()
        #endif
    }

    public static func noteDecoded() {
        #if DEBUG && os(iOS)
            guard enabled else { return }
            FeedStressRuntime.shared.noteDecoded()
        #endif
    }

    /// Call-site `#fileID` selects enqueue vs Metal. Not scanout.
    public static func notePresent(file: StaticString = #fileID) {
        #if DEBUG && os(iOS)
            guard enabled else { return }
            FeedStressRuntime.shared.notePresent(file: file)
        #endif
    }

    public static func noteIdentityEnqueue() {
        #if DEBUG && os(iOS)
            guard enabled else { return }
            FeedStressRuntime.shared.noteIdentityEnqueue()
        #endif
    }

    public static func noteMetalPresent() {
        #if DEBUG && os(iOS)
            guard enabled else { return }
            FeedStressRuntime.shared.noteMetalPresent()
        #endif
    }

    public static func shouldDropPacket(seq: UInt64) -> Bool {
        #if DEBUG && os(iOS)
            guard enabled else { return false }
            return FeedStressRuntime.shared.shouldDropPacket(seq: seq)
        #else
            return false
        #endif
    }

    /// Always 0. Do not sleep on the UDP ACK queue.
    public static func packetDelayNanoseconds() -> UInt64 { 0 }

    /// Call before decode-success accounting. True means swallow this output.
    public static func shouldSilenceOutput(now: TimeInterval = ProcessInfo.processInfo.systemUptime)
        -> Bool
    {
        #if DEBUG && os(iOS)
            guard enabled else { return false }
            return FeedStressRuntime.shared.shouldSilenceOutput(now: now)
        #else
            return false
        #endif
    }

    public static func snapshotLine() -> String {
        #if DEBUG && os(iOS)
            guard enabled else { return "" }
            return FeedStressRuntime.shared.snapshotLine()
        #else
            return ""
        #endif
    }
}

/// What the stress run's one reconnect attempt found, recorded as `reconnect=` in each snapshot.
public enum FeedStressReconnect: String, Equatable, Sendable {
    /// The feed was already live; nothing to reconnect.
    case live
    /// No saved camera the app can reconnect.
    case none
    /// More than one saved camera matched; the run does not pick one.
    case ambiguous
    /// The app asked its one matching saved camera to reconnect.
    case requested

    /// The record of an app that never reconnects a saved camera from the seam.
    public static func observed(isLive: Bool) -> FeedStressReconnect {
        isLive ? .live : .none
    }
}

/// The app's side of the stress run: its live camera's state and the commands the teardown uses
/// to put the operator's settings back. Main actor; called on the run's one-second tick.
@MainActor
public protocol FeedStressHost: AnyObject {
    var feedStressIsLive: Bool { get }
    var feedStressStatus: CameraStatus { get }
    var feedStressBodyFamily: CameraBodyFamily { get }
    func feedStressAssistIsOn(_ tool: MonitorAssistSelection) -> Bool
    func feedStressToggleAssist(_ tool: MonitorAssistSelection)
    /// Called once per run, on the first tick with a host. Reconnects a saved camera if the app
    /// has a rule for it, and says what it did.
    func feedStressReconnect() -> FeedStressReconnect
    func feedStressEndGimbalStick()
    /// Stops a recording the run started (`OPV_FEED_STRESS_RECORD=1`).
    func feedStressStopRecording()
    func feedStressSetISO(_ index: IsoIndex)
    func feedStressSetIsoLimit(_ limit: IsoLimit)
    func feedStressSetWhiteBalanceAuto(tint: Int)
    func feedStressSetWhiteBalanceCustom(kelvin: Int, tint: Int)
}

/// Fault plan from `OPV_FEED_STRESS_INJECT`, e.g. `loss:0.05,burst:6:120,outputSilenceMs:900`.
struct FeedStressPlan: Equatable {
    var lossProbability = 0.0
    var burstDropCount = 0
    var burstEveryN = 0
    var outputSilenceMs = 0
    var configured = false

    static func parse(_ raw: String) -> FeedStressPlan {
        var plan = FeedStressPlan()
        guard !raw.isEmpty else { return plan }
        plan.configured = true
        for part in raw.split(separator: ",") {
            let item = part.split(separator: ":", maxSplits: 3).map(String.init)
            guard let key = item.first else { continue }
            switch key {
            case "loss":
                plan.lossProbability = Double(item.dropFirst().first ?? "0") ?? 0
            case "burst":
                plan.burstDropCount = Int(item.dropFirst().first ?? "0") ?? 0
                plan.burstEveryN = Int(item.dropFirst().dropFirst().first ?? "0") ?? 0
            case "outputSilenceMs":
                plan.outputSilenceMs = Int(item.dropFirst().first ?? "0") ?? 0
            default:
                break
            }
        }
        plan.lossProbability = min(max(plan.lossProbability, 0), 0.5)
        plan.burstDropCount = min(max(plan.burstDropCount, 0), 24)
        plan.burstEveryN = min(max(plan.burstEveryN, 0), 400)
        plan.outputSilenceMs = min(max(plan.outputSilenceMs, 0), 4_000)
        return plan
    }
}

/// The operator's settings when the feed first went live, put back at teardown.
struct FeedStressBaseline: Equatable {
    var captured = false
    var isoIndex: IsoIndex?
    var isoLimit: IsoLimit?
    var whiteBalance: WhiteBalance?
    var peaking = false
    var falseColor = false
    var waveform = false
    var lut = false

    /// Different status fields can arrive on different callbacks. The settings sweep refuses
    /// mutation until all are captured.
    mutating func fill(from status: CameraStatus) {
        if isoIndex == nil { isoIndex = status.isoIndex }
        if isoLimit == nil { isoLimit = status.isoLimit }
        if whiteBalance == nil { whiteBalance = status.whiteBalance }
    }

    /// `needsLimit`: the body offers ISO Auto, so its ceiling must be captured too.
    func isReady(needsLimit: Bool) -> Bool {
        isoIndex != nil && whiteBalance != nil && (!needsLimit || isoLimit != nil)
    }
}

#if DEBUG && os(iOS)

    private let feedStressBeginPrefix = "com.opencapture.opc.feed-stress.begin."
    private let feedStressPassPrefix = "com.opencapture.opc.feed-stress.pass."
    private let feedStressFailPrefix = "com.opencapture.opc.feed-stress.fail."
    private let feedStressArmInject = "com.opencapture.opc.feed-stress.arm-inject"
    private let feedStressDisarmInject = "com.opencapture.opc.feed-stress.disarm-inject"
    private let feedStressTeardown = "com.opencapture.opc.feed-stress.teardown"
    private let feedStressAttached = "com.opencapture.opc.feed-stress.attached-v1"

    private let feedStressScenarios = [
        "settingsOpenClose", "assistToggles", "rotation", "cameraSettingChanges",
        "boundedJoystick", "lifecycleInterrupt", "briefRecord", "injectFault",
        "mediaReturn", "steadyFeed", "settingsSweep", "gimbalStorm", "faultMediaReturn",
        "faultAutomaticRecovery",
    ]

    /// The runtime's counters behind one lock (Foundation, so the module needs no `os`).
    private final class FeedStressLock<State>: @unchecked Sendable {
        private let lock = NSLock()
        private var state: State
        init(initialState: State) { state = initialState }
        func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
            lock.lock()
            defer { lock.unlock() }
            return try body(&state)
        }
    }

    private struct FeedStressCounters {
        var sourceObservedPackets = 0
        var sourceObservedAUs = 0
        var sourceDeliveredPackets = 0
        var sourceDeliveredAUs = 0
        var decodeSubmits = 0
        var decodedOutputs = 0
        var presents = 0
        var presentEnqueue = 0
        var presentMetal = 0
        var lastSourceObservedAt: TimeInterval?
        var lastSourceDeliveredAt: TimeInterval?
        var lastDecodeSubmitAt: TimeInterval?
        var lastDecodedAt: TimeInterval?
        var lastPresentAt: TimeInterval?
        var lastEnqueueAt: TimeInterval?
        var lastMetalAt: TimeInterval?
        var windowSourceHz = 0.0
        var windowDecodeHz = 0.0
        var windowPresentHz = 0.0
        var healthySince: TimeInterval?
        var injectArmedAt: TimeInterval?
        var silenceUntil: TimeInterval?
        var silenceConsumed = false
        var packetIndex: UInt64 = 0
        var burstLeft = 0
        var halt = ""
        var injectDrops = 0
        var injectSilences = 0
        var recording = false
        var cameraFamily = "unknown"
        var reconnect = "idle"
        var settingsBaselineReady = false
    }

    private struct FeedStressRNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func nextDouble() -> Double {
            Double(next() >> 11) / Double(1 << 53)
        }
    }

    final class FeedStressRuntime: @unchecked Sendable {
        static let shared = FeedStressRuntime()

        private let lock = FeedStressLock(initialState: FeedStressCounters())
        private let io = DispatchQueue(label: "opc.feed-stress", qos: .utility)
        private var installed = false
        private var notifications: DarwinNotificationObserver?
        private var seed: UInt64 = 20_260_914
        private var limitS: TimeInterval = 300
        private var configurationToken = ""
        private var startedAt: TimeInterval = 0
        private var wallStart = Date()
        private var runId = ""
        private var directory: URL?
        private var plan = FeedStressPlan()
        private var rng: FeedStressRNG
        private var timer: DispatchSourceTimer?
        private var probe: FeedStressProbeView?
        private var baseline = FeedStressBaseline()
        private var restored = false
        private var prevDeliveredPackets = 0
        private var prevDecoded = 0
        private var prevPresents = 0
        private var reconnectAttempted = false
        private var didNotifyInjection = false
        private var onInjectionActivated: @Sendable () -> Void = {}
        @MainActor private var host: @MainActor () -> (any FeedStressHost)? = { nil }
        @MainActor private var originalIdleTimerDisabled: Bool?

        private init() {
            rng = FeedStressRNG(state: 20_260_914)
        }

        func installIfRequested(
            host: @escaping @MainActor () -> (any FeedStressHost)?,
            onInjectionActivated: @escaping @Sendable () -> Void
        ) {
            let env = ProcessInfo.processInfo.environment
            guard env["OPV_FEED_STRESS"] == "1" else { return }
            let first: Bool = lock.withLock { _ in
                guard !installed else { return false }
                installed = true
                self.onInjectionActivated = onInjectionActivated
                seed = UInt64(env["OPV_FEED_STRESS_SEED"] ?? "") ?? 20_260_914
                limitS = TimeInterval(env["OPV_FEED_STRESS_LIMIT_S"] ?? "") ?? 300
                if limitS < 60 { limitS = 60 }
                if limitS > 1_800 { limitS = 1_800 }
                let recording = env["OPV_FEED_STRESS_RECORD"] == "1" ? "1" : "0"
                let injection = env["OPV_FEED_STRESS_INJECT"] ?? ""
                configurationToken = Data(
                    "\(seed)|\(Int(limitS))|\(recording)|\(injection)".utf8
                ).base64EncodedString()
                startedAt = ProcessInfo.processInfo.systemUptime
                wallStart = Date()
                rng = FeedStressRNG(state: seed == 0 ? 1 : seed)
                plan = FeedStressPlan.parse(env["OPV_FEED_STRESS_INJECT"] ?? "")
                let stamp = ISO8601DateFormatter().string(from: wallStart)
                    .replacingOccurrences(of: ":", with: "")
                runId = "s\(seed)-\(stamp)"
                return true
            }
            guard first else { return }
            prepareDirectory()
            writeHeader()
            registerNotifications()
            startTicker()
            Task { @MainActor in
                self.host = host
                self.originalIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
                UIApplication.shared.isIdleTimerDisabled = true
                self.attachProbe()
            }
        }

        func noteSourceObserved(videoPackets: Int, accessUnits: Int) {
            let now = ProcessInfo.processInfo.systemUptime
            lock.withLock {
                $0.sourceObservedPackets += max(0, videoPackets)
                $0.sourceObservedAUs += max(0, accessUnits)
                if videoPackets > 0 || accessUnits > 0 { $0.lastSourceObservedAt = now }
            }
        }

        func noteSourceDelivered(videoPackets: Int, accessUnits: Int) {
            let now = ProcessInfo.processInfo.systemUptime
            lock.withLock {
                $0.sourceDeliveredPackets += max(0, videoPackets)
                $0.sourceDeliveredAUs += max(0, accessUnits)
                if videoPackets > 0 || accessUnits > 0 { $0.lastSourceDeliveredAt = now }
            }
        }

        func noteDecodeSubmit() {
            let now = ProcessInfo.processInfo.systemUptime
            lock.withLock {
                $0.decodeSubmits += 1
                $0.lastDecodeSubmitAt = now
            }
        }

        func noteDecoded() {
            let now = ProcessInfo.processInfo.systemUptime
            lock.withLock {
                $0.decodedOutputs += 1
                $0.lastDecodedAt = now
            }
        }

        func notePresent(file: StaticString) {
            let fileID = "\(file)"
            if fileID.contains("LiveMonitorFx") {
                noteMetalPresent()
            } else if fileID.contains("HevcDecoder") {
                noteIdentityEnqueue()
            } else {
                let now = ProcessInfo.processInfo.systemUptime
                lock.withLock {
                    $0.presents += 1
                    $0.lastPresentAt = now
                }
            }
        }

        func noteIdentityEnqueue() {
            let now = ProcessInfo.processInfo.systemUptime
            lock.withLock {
                $0.presentEnqueue += 1
                $0.presents += 1
                $0.lastEnqueueAt = now
                $0.lastPresentAt = now
            }
        }

        func noteMetalPresent() {
            let now = ProcessInfo.processInfo.systemUptime
            lock.withLock {
                $0.presentMetal += 1
                $0.presents += 1
                $0.lastMetalAt = now
                $0.lastPresentAt = now
            }
        }

        var injectionDidActivate: Bool {
            lock.withLock { $0.injectDrops > 0 || $0.injectSilences > 0 || $0.silenceConsumed }
        }

        func shouldDropPacket(seq: UInt64) -> Bool {
            let now = ProcessInfo.processInfo.systemUptime
            let dropped = lock.withLock { state -> Bool in
                guard plan.configured, injectActive(state, now: now) else { return false }
                state.packetIndex &+= 1
                if state.burstLeft > 0 {
                    state.burstLeft -= 1
                    state.injectDrops += 1
                    return true
                }
                if plan.burstEveryN > 0, plan.burstDropCount > 0,
                    state.packetIndex.isMultiple(of: UInt64(plan.burstEveryN))
                {
                    state.burstLeft = max(0, plan.burstDropCount - 1)
                    state.injectDrops += 1
                    return true
                }
                if plan.lossProbability > 0, rng.nextDouble() < plan.lossProbability {
                    state.injectDrops += 1
                    return true
                }
                _ = seq
                return false
            }
            if dropped { notifyInjectionActivated() }
            return dropped
        }

        func shouldSilenceOutput(now: TimeInterval) -> Bool {
            let silenced = lock.withLock { state -> Bool in
                guard plan.configured, injectActive(state, now: now) else { return false }
                guard plan.outputSilenceMs > 0 else { return false }
                if state.silenceUntil == nil, !state.silenceConsumed {
                    state.silenceUntil = now + TimeInterval(plan.outputSilenceMs) / 1_000
                    state.silenceConsumed = true
                }
                if let until = state.silenceUntil, now < until {
                    state.injectSilences += 1
                    return true
                }
                return false
            }
            if silenced { notifyInjectionActivated() }
            return silenced
        }

        private func notifyInjectionActivated() {
            let first: Bool = lock.withLock { _ in
                if didNotifyInjection { return false }
                didNotifyInjection = true
                return true
            }
            guard first else { return }
            // The owned snapshot producer promotes incident origin from this run state.
            onInjectionActivated()
        }

        func snapshotLine() -> String {
            let now = ProcessInfo.processInfo.systemUptime
            let thermal = Self.thermalToken()
            return lock.withLock { state in
                self.refreshHealth(&state, now: now, thermal: thermal)
                return self.render(state, now: now, thermal: thermal)
            }
        }

        func handleDarwin(_ name: String) {
            io.async { [weak self] in
                self?.dispatchDarwin(name)
            }
        }

        private func injectActive(_ state: FeedStressCounters, now: TimeInterval) -> Bool {
            guard let armed = state.injectArmedAt else { return false }
            if now - armed > 8 { return false }
            guard let healthy = state.healthySince, now - healthy >= 30 else { return false }
            return true
        }

        private func refreshHealth(
            _ state: inout FeedStressCounters, now: TimeInterval, thermal: String
        ) {
            let sourceFresh =
                state.lastSourceDeliveredAt.map { now - $0 < 2.0 } == true
                || state.lastSourceObservedAt.map { now - $0 < 2.0 } == true
            let decodeFresh = state.lastDecodedAt.map { now - $0 < 2.0 } == true
            if sourceFresh && decodeFresh {
                if state.healthySince == nil { state.healthySince = now }
            } else if state.injectArmedAt == nil {
                state.healthySince = nil
            }
            if thermal == "serious" || thermal == "critical" {
                state.halt = "thermal"
            } else if now - startedAt >= limitS {
                state.halt = "time"
            }
            if let armed = state.injectArmedAt, now - armed > 8 {
                state.injectArmedAt = nil
            }
        }

        private func render(_ state: FeedStressCounters, now: TimeInterval, thermal: String)
            -> String
        {
            let age = { (mark: TimeInterval?) -> Int in
                guard let mark else { return -1 }
                return Int((now - mark) * 1_000)
            }
            let hook =
                (state.decodedOutputs > 0 || state.presents > 0
                    || state.sourceObservedPackets > 0)
                ? "counters" : "none"
            let armed = injectActive(state, now: now) ? 1 : 0
            return [
                "v=1",
                "srcObsP=\(state.sourceObservedPackets)",
                "srcObsAU=\(state.sourceObservedAUs)",
                "srcDelP=\(state.sourceDeliveredPackets)",
                "srcDelAU=\(state.sourceDeliveredAUs)",
                "decIn=\(state.decodeSubmits)",
                "decOut=\(state.decodedOutputs)",
                "pres=\(state.presents)",
                "presEnqueue=\(state.presentEnqueue)",
                "presMetal=\(state.presentMetal)",
                "presClaim=admission",
                "srcHz=\(String(format: "%.1f", state.windowSourceHz))",
                "decHz=\(String(format: "%.1f", state.windowDecodeHz))",
                "presHz=\(String(format: "%.1f", state.windowPresentHz))",
                "srcAgeMs=\(age(state.lastSourceDeliveredAt ?? state.lastSourceObservedAt))",
                "srcObsAgeMs=\(age(state.lastSourceObservedAt))",
                "decAgeMs=\(age(state.lastDecodedAt))",
                "presAgeMs=\(age(state.lastPresentAt))",
                "enqueueAgeMs=\(age(state.lastEnqueueAt))",
                "metalAgeMs=\(age(state.lastMetalAt))",
                "therm=\(thermal)",
                "rec=\(state.recording ? 1 : 0)",
                "hook=\(hook)",
                "inj=\(armed)",
                "injDrop=\(state.injectDrops)",
                "injSil=\(state.injectSilences)",
                "delayLimited=1",
                "halt=\(state.halt.isEmpty ? "0" : state.halt)",
                "t=\(String(format: "%.1f", now - startedAt))",
                "run=\(runId)",
                "config=\(configurationToken)",
                "family=\(state.cameraFamily)",
                "reconnect=\(state.reconnect)",
                "settingsBaseline=\(state.settingsBaselineReady ? 1 : 0)",
            ].joined(separator: " ")
        }

        private func startTicker() {
            let timer = DispatchSource.makeTimerSource(queue: io)
            timer.schedule(deadline: .now() + .milliseconds(400), repeating: .seconds(1))
            timer.setEventHandler { [weak self] in
                self?.tick()
            }
            timer.resume()
            self.timer = timer
        }

        private func tick() {
            Task { @MainActor [weak self] in
                self?.publishSnapshot()
            }
        }

        @MainActor
        private func publishSnapshot() {
            if probe == nil || probe?.superview == nil {
                attachProbe()
            }
            let host = host()
            let recording = host?.feedStressStatus.isRecording ?? false
            let family = host.map { String(describing: $0.feedStressBodyFamily) } ?? "unknown"
            captureBaselineIfNeeded(host)
            reconnectIfNeeded(host)
            lock.withLock { state in
                state.recording = recording
                if family != "unknown" { state.cameraFamily = family }
                let srcDelta = state.sourceDeliveredPackets - self.prevDeliveredPackets
                let decDelta = state.decodedOutputs - self.prevDecoded
                let presDelta = state.presents - self.prevPresents
                state.windowSourceHz = Double(max(0, srcDelta))
                state.windowDecodeHz = Double(max(0, decDelta))
                state.windowPresentHz = Double(max(0, presDelta))
                self.prevDeliveredPackets = state.sourceDeliveredPackets
                self.prevDecoded = state.decodedOutputs
                self.prevPresents = state.presents
            }
            let line = snapshotLine()
            probe?.accessibilityValue = line
            append("snapshots.ndjson", line + "\n")
            let halt = lock.withLock { $0.halt }
            if !halt.isEmpty {
                runTeardown(reason: halt)
            }
        }

        @MainActor
        private func reconnectIfNeeded(_ host: (any FeedStressHost)?) {
            guard !reconnectAttempted else { return }
            guard let host else { return }
            reconnectAttempted = true
            let record = host.feedStressReconnect()
            lock.withLock { $0.reconnect = record.rawValue }
        }

        @MainActor
        private func captureBaselineIfNeeded(_ host: (any FeedStressHost)?) {
            guard let host else { return }
            guard host.feedStressIsLive else { return }
            let status = host.feedStressStatus
            if baseline.captured {
                baseline.fill(from: status)
                let ready = baseline.isReady(needsLimit: CaptureLists.offersIsoAuto(from: status))
                lock.withLock { $0.settingsBaselineReady = ready }
                return
            }
            guard status.isoIndex != nil || status.iso > 0 else { return }
            baseline = FeedStressBaseline(
                captured: true,
                isoIndex: status.isoIndex,
                isoLimit: status.isoLimit,
                whiteBalance: status.whiteBalance,
                peaking: host.feedStressAssistIsOn(.peaking),
                falseColor: host.feedStressAssistIsOn(.falseColor),
                waveform: host.feedStressAssistIsOn(.waveform),
                lut: host.feedStressAssistIsOn(.lut)
            )
        }

        private func registerNotifications() {
            var names = feedStressScenarios.flatMap {
                [feedStressBeginPrefix + $0, feedStressPassPrefix + $0, feedStressFailPrefix + $0]
            }
            names.append(contentsOf: [
                feedStressArmInject, feedStressDisarmInject, feedStressTeardown, feedStressAttached,
            ])
            notifications = DarwinNotificationObserver(names: names) { [weak self] name in
                self?.handleDarwin(name)
            }
        }

        private func dispatchDarwin(_ name: String) {
            if name.hasPrefix(feedStressBeginPrefix) {
                mark("begin", String(name.dropFirst(feedStressBeginPrefix.count)), result: "")
            } else if name.hasPrefix(feedStressPassPrefix) {
                mark("end", String(name.dropFirst(feedStressPassPrefix.count)), result: "pass")
            } else if name.hasPrefix(feedStressFailPrefix) {
                mark("end", String(name.dropFirst(feedStressFailPrefix.count)), result: "fail")
            } else if name == feedStressArmInject {
                armInject()
            } else if name == feedStressDisarmInject {
                lock.withLock { $0.injectArmedAt = nil }
                mark("inject", "disarm", result: "")
            } else if name == feedStressTeardown {
                runTeardown(reason: "test")
            } else if name == feedStressAttached {
                mark("runner", "attached-v1", result: "pass")
            }
        }

        private func armInject() {
            let now = ProcessInfo.processInfo.systemUptime
            let ok = lock.withLock { state -> Bool in
                guard self.plan.configured else { return false }
                guard let healthy = state.healthySince, now - healthy >= 30 else { return false }
                state.injectArmedAt = now
                state.silenceUntil = nil
                state.silenceConsumed = false
                return true
            }
            mark("inject", ok ? "arm" : "arm-rejected", result: ok ? "pass" : "fail")
        }

        private func mark(_ kind: String, _ scenario: String, result: String) {
            let now = ProcessInfo.processInfo.systemUptime
            let line = snapshotLine()
            let row =
                "{\"t\":\(String(format: "%.1f", now - startedAt)),\"kind\":\"\(kind)\",\"scenario\":\"\(scenario)\",\"result\":\"\(result)\"}\n"
            append("events.ndjson", row)
            append("events.ndjson", "{\"snapshot\":\"\(line)\"}\n")
        }

        @MainActor
        private func attachProbe() {
            if let probe, probe.superview != nil { return }
            guard
                let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene }).first,
                let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
            else { return }
            let probe = FeedStressProbeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            probe.isUserInteractionEnabled = false
            probe.backgroundColor = .clear
            probe.isAccessibilityElement = true
            probe.accessibilityIdentifier = "feed.stress.snapshot"
            probe.accessibilityLabel = "Feed stress snapshot"
            probe.accessibilityValue = snapshotLine()
            window.addSubview(probe)
            self.probe = probe
        }

        private func runTeardown(reason: String) {
            let already = lock.withLock { state -> Bool in
                if self.restored { return true }
                self.restored = true
                if state.halt.isEmpty { state.halt = reason }
                state.injectArmedAt = nil
                state.burstLeft = 0
                state.silenceUntil = nil
                return false
            }
            if already { return }
            timer?.cancel()
            timer = nil
            Task { @MainActor in
                Self.stopMotionAndRestore(self.baseline, host: self.host())
                if let original = self.originalIdleTimerDisabled {
                    UIApplication.shared.isIdleTimerDisabled = original
                }
            }
            writeSummary(reason: reason)
        }

        @MainActor
        private static func stopMotionAndRestore(
            _ baseline: FeedStressBaseline, host: (any FeedStressHost)?
        ) {
            guard let host else { return }
            host.feedStressEndGimbalStick()
            guard baseline.captured else { return }
            if ProcessInfo.processInfo.environment["OPV_FEED_STRESS_RECORD"] == "1",
                host.feedStressStatus.isRecording
            {
                host.feedStressStopRecording()
            }
            host.feedStressEndGimbalStick()
            if let iso = baseline.isoIndex, iso != host.feedStressStatus.isoIndex {
                host.feedStressSetISO(iso)
            }
            if let limit = baseline.isoLimit, limit != host.feedStressStatus.isoLimit {
                host.feedStressSetIsoLimit(limit)
            }
            if let wb = baseline.whiteBalance {
                switch wb.mode {
                case .auto:
                    host.feedStressSetWhiteBalanceAuto(tint: wb.tint)
                case .custom:
                    host.feedStressSetWhiteBalanceCustom(kelvin: wb.kelvin, tint: wb.tint)
                }
            }
            let wanted: [(MonitorAssistSelection, Bool)] = [
                (.peaking, baseline.peaking),
                (.falseColor, baseline.falseColor),
                (.waveform, baseline.waveform),
                (.lut, baseline.lut),
            ]
            for (tool, on) in wanted where host.feedStressAssistIsOn(tool) != on {
                host.feedStressToggleAssist(tool)
            }
        }

        private func prepareDirectory() {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                .first
            guard let docs else { return }
            let dir = docs.appendingPathComponent("feed-stress", isDirectory: true)
                .appendingPathComponent(runId, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            directory = dir
        }

        private func writeHeader() {
            let bundle = Bundle.main
            let version =
                bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? ""
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            let revision =
                bundle.object(forInfoDictionaryKey: "OPCSourceRevision") as? String ?? "unknown"
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let osText = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            let inject =
                (ProcessInfo.processInfo.environment["OPV_FEED_STRESS_INJECT"] ?? "")
                .replacingOccurrences(of: "\"", with: "")
            let body = """
                {"seed":\(seed),"limitS":\(Int(limitS)),"runId":"\(runId)","app":"\(version)","build":"\(build)","revision":"\(revision)","os":"\(osText)","hw":"\(Self.machineIdentifier)","inject":"\(inject)","delayLimited":true,"presClaim":"admission","started":"\(ISO8601DateFormatter().string(from: wallStart))"}\n
                """
            append("header.json", body)
        }

        private func writeSummary(reason: String) {
            let line = snapshotLine()
            let body = """
                {"reason":"\(reason)","elapsedS":\(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - startedAt)),"final":"\(line)"}\n
                """
            append("summary.json", body)
        }

        private func append(_ name: String, _ text: String) {
            guard let directory else { return }
            let url = directory.appendingPathComponent(name)
            io.async {
                let data = Data(text.utf8)
                if FileManager.default.fileExists(atPath: url.path) {
                    if let handle = try? FileHandle(forWritingTo: url) {
                        defer { try? handle.close() }
                        _ = try? handle.seekToEnd()
                        try? handle.write(contentsOf: data)
                    }
                } else {
                    try? data.write(to: url)
                }
            }
        }

        private static func thermalToken() -> String {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: return "nominal"
            case .fair: return "fair"
            case .serious: return "serious"
            case .critical: return "critical"
            @unknown default: return "unknown"
            }
        }

        private static var machineIdentifier: String {
            var info = utsname()
            uname(&info)
            return withUnsafePointer(to: &info.machine) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
            }
        }
    }

    private final class FeedStressProbeView: UIView {}

#endif
