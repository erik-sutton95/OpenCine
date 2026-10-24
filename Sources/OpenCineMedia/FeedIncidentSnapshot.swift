import Foundation

/// Schema for typed feed-incident bundles. Bump when grouping fields change.
public enum FeedIncidentSchema {
    public static let version = 1
}

/// Bounded origin of a feed session. Legacy records without the field are `unknown`.
public enum FeedIncidentTestSource: String, Equatable, Sendable, Codable {
    case manual
    case automation
    case faultInjection
    case verification
    case unknown

    public var rank: Int {
        switch self {
        case .unknown: return 0
        case .manual: return 1
        case .automation: return 2
        case .faultInjection: return 3
        case .verification: return 4
        }
    }

    public static func parse(_ raw: String?) -> FeedIncidentTestSource {
        guard let raw else { return .unknown }
        return FeedIncidentTestSource(rawValue: raw) ?? .unknown
    }

    /// Current-run derivation only. Never apply this to cached reports.
    public static func derive(
        verification: Bool,
        injectionActivated: Bool,
        automation: Bool
    ) -> FeedIncidentTestSource {
        if verification { return .verification }
        if injectionActivated { return .faultInjection }
        if automation { return .automation }
        return .manual
    }
}

/// Artifact identity distinct from marketing version/build. Token length holds
/// `ios-`/`android-` plus 32 hex characters.
public enum FeedIncidentBuildIdentity {
    public static let maxLength = 64

    public static func parse(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "unknown" }
        return FeedIncidentPrivacy.token(trimmed, max: maxLength)
    }
}

/// Bounds for the incident recorder. These are capture limits, not live budgets.
public enum FeedIncidentBounds {
    public static let preludeSeconds: TimeInterval = 60
    public static let aftermathSeconds: TimeInterval = 30
    /// Neutral 2 s freeze bound; OpenCineDJI tests pin it to `FeedWatchdog.stallThreshold`.
    public static let stallThreshold: TimeInterval = FeedPresentPolicy.freezeThreshold
    public static let stringLength = 96
    public static let ringCount = 60
    public static let breadcrumbRing = 32
    public static let repairRing = 32
    public static let duringCount = 60
    public static let errorClasses = 16
}

/// Retention for on-device incident spool. First cap reached wins.
public struct FeedIncidentLimits: Equatable, Sendable {
    public var maxBundles: Int
    public var maxBundleBytes: Int
    public var maxSpoolBytes: Int
    public var ttl: TimeInterval

    public init(
        maxBundles: Int = 20,
        maxBundleBytes: Int = 262_144,
        maxSpoolBytes: Int = 10_485_760,
        ttl: TimeInterval = 604_800
    ) {
        self.maxBundles = max(1, maxBundles)
        self.maxBundleBytes = max(1_024, maxBundleBytes)
        self.maxSpoolBytes = max(self.maxBundleBytes, maxSpoolBytes)
        self.ttl = max(1, ttl)
    }

    public static let production = FeedIncidentLimits()
}

/// Ephemeral live-session identity. No camera serial or operator identifier.
public struct FeedIncidentSessionContext: Equatable, Sendable {
    public var sessionID: String
    public var appVersion: String
    public var appBuild: String
    public var sourceRevision: String
    public var osName: String
    public var osVersion: String
    public var hardwareClass: String
    public var cameraFamily: String
    public var cameraFirmware: String?
    public var decoderGeneration: Int
    public var socketGeneration: Int
    public var testSource: FeedIncidentTestSource
    public var buildIdentity: String

    public init(
        sessionID: String,
        appVersion: String,
        appBuild: String,
        sourceRevision: String,
        osName: String,
        osVersion: String,
        hardwareClass: String,
        cameraFamily: String,
        cameraFirmware: String? = nil,
        decoderGeneration: Int = 0,
        socketGeneration: Int = 0,
        testSource: FeedIncidentTestSource = .unknown,
        buildIdentity: String = "unknown"
    ) {
        self.sessionID = FeedIncidentPrivacy.token(sessionID)
        self.appVersion = FeedIncidentPrivacy.token(appVersion, max: 32)
        self.appBuild = FeedIncidentPrivacy.token(appBuild, max: 32)
        self.sourceRevision = FeedIncidentPrivacy.token(sourceRevision, max: 64)
        self.osName = FeedIncidentPrivacy.token(osName, max: 16)
        self.osVersion = FeedIncidentPrivacy.token(osVersion, max: 64)
        self.hardwareClass = FeedIncidentPrivacy.token(hardwareClass, max: 32)
        self.cameraFamily = FeedIncidentPrivacy.token(cameraFamily, max: 32)
        self.cameraFirmware = cameraFirmware.map { FeedIncidentPrivacy.token($0, max: 32) }
        self.decoderGeneration = max(0, decoderGeneration)
        self.socketGeneration = max(0, socketGeneration)
        self.testSource = testSource
        self.buildIdentity = FeedIncidentBuildIdentity.parse(buildIdentity)
    }
}

public enum FeedIncidentKind: String, Equatable, Sendable, Codable {
    case freshInputStaleOutput
    case decoderError
    case presentStalled
    case assistStalled
    case transportStall
    case unexpectedDisconnect
}

public enum FeedIncidentFailingStage: String, Equatable, Sendable, Codable {
    case packet
    case accessUnit
    case decodeAccept
    case decodedOutput
    case assistOutput
    case presentation
}

public enum FeedIncidentOutcome: String, Equatable, Sendable, Codable {
    case open
    case recovered
    case interrupted
    case exhausted
    case suppressed
    /// The operator disconnected while the incident was still open: the ladder
    /// had not restored picture. Not a suppression.
    case userEnded
}

public enum FeedIncidentSuppression: String, Equatable, Sendable, Codable {
    case none
    case disconnected
    case playback
    case background
    case neverEstablished
}

public enum FeedDecoderErrorOrigin: String, Equatable, Sendable, Codable {
    case none
    case sync
    case callback
    case create
}

public enum FeedIncidentBreadcrumbKind: String, Equatable, Sendable, Codable {
    case settingsEnter
    case settingsExit
    case assistChange
    case sceneActivity
    case surfaceAttach
    case surfaceDetach
    case decoderCreate
    case decoderInvalidate
    case pathChange
    case cameraCommand
}

public enum FeedRepairPhase: String, Equatable, Sendable, Codable {
    case requested
    case blocked
    case locallySent
    case peerResponse
    case pictureRestored
}

public struct FeedIncidentRates: Equatable, Sendable, Codable {
    public var packetHz: Double
    public var accessUnitHz: Double
    public var decodeSubmitHz: Double
    public var decodeAcceptHz: Double
    public var decodedOutputHz: Double
    public var assistOutputHz: Double
    public var presentHz: Double
    public var ackHz: Double
    public var observed: FeedIncidentRateObservation?

    public init(
        packetHz: Double = 0,
        accessUnitHz: Double = 0,
        decodeSubmitHz: Double = 0,
        decodeAcceptHz: Double = 0,
        decodedOutputHz: Double = 0,
        assistOutputHz: Double = 0,
        presentHz: Double = 0,
        ackHz: Double = 0
    ) {
        self.packetHz = FeedIncidentPrivacy.rate(packetHz)
        self.accessUnitHz = FeedIncidentPrivacy.rate(accessUnitHz)
        self.decodeSubmitHz = FeedIncidentPrivacy.rate(decodeSubmitHz)
        self.decodeAcceptHz = FeedIncidentPrivacy.rate(decodeAcceptHz)
        self.decodedOutputHz = FeedIncidentPrivacy.rate(decodedOutputHz)
        self.assistOutputHz = FeedIncidentPrivacy.rate(assistOutputHz)
        self.presentHz = FeedIncidentPrivacy.rate(presentHz)
        self.ackHz = FeedIncidentPrivacy.rate(ackHz)
        self.observed = nil
    }

    public init(
        packetHz: Double = 0, accessUnitHz: Double = 0, decodeSubmitHz: Double = 0,
        decodeAcceptHz: Double = 0, decodedOutputHz: Double = 0, assistOutputHz: Double = 0,
        presentHz: Double = 0, ackHz: Double = 0, observed: FeedIncidentRateObservation
    ) {
        self.init(
            packetHz: packetHz, accessUnitHz: accessUnitHz, decodeSubmitHz: decodeSubmitHz,
            decodeAcceptHz: decodeAcceptHz, decodedOutputHz: decodedOutputHz,
            assistOutputHz: assistOutputHz,
            presentHz: presentHz, ackHz: ackHz)
        self.observed = observed
    }
}

public struct FeedIncidentAges: Equatable, Sendable, Codable {
    public var packetAge: TimeInterval?
    public var accessUnitAge: TimeInterval?
    public var decodeAcceptAge: TimeInterval?
    public var decodedOutputAge: TimeInterval?
    public var assistOutputAge: TimeInterval?
    public var presentAge: TimeInterval?
    /// Any camera control frame on the link (telemetry, command replies).
    /// Fresh while `packetAge` is stale means only the video stream stopped.
    public var statusAge: TimeInterval?
    /// Last UDP send the network stack rejected. Nil means none this socket.
    public var sendErrorAge: TimeInterval?
    /// POSIX code of that rejection (65 EHOSTUNREACH, 55 ENOBUFS, 64 EHOSTDOWN, ...).
    public var sendErrorCode: Int?
    /// Camera's reply to the 1 Hz uplink probe: proof the camera still hears us.
    public var uplinkReplyAge: TimeInterval?

    public init(
        packetAge: TimeInterval? = nil,
        accessUnitAge: TimeInterval? = nil,
        decodeAcceptAge: TimeInterval? = nil,
        decodedOutputAge: TimeInterval? = nil,
        assistOutputAge: TimeInterval? = nil,
        presentAge: TimeInterval? = nil,
        statusAge: TimeInterval? = nil,
        sendErrorAge: TimeInterval? = nil,
        sendErrorCode: Int? = nil,
        uplinkReplyAge: TimeInterval? = nil
    ) {
        self.packetAge = FeedIncidentPrivacy.age(packetAge)
        self.accessUnitAge = FeedIncidentPrivacy.age(accessUnitAge)
        self.decodeAcceptAge = FeedIncidentPrivacy.age(decodeAcceptAge)
        self.decodedOutputAge = FeedIncidentPrivacy.age(decodedOutputAge)
        self.assistOutputAge = FeedIncidentPrivacy.age(assistOutputAge)
        self.presentAge = FeedIncidentPrivacy.age(presentAge)
        self.statusAge = FeedIncidentPrivacy.age(statusAge)
        self.sendErrorAge = FeedIncidentPrivacy.age(sendErrorAge)
        self.sendErrorCode = sendErrorCode
        self.uplinkReplyAge = FeedIncidentPrivacy.age(uplinkReplyAge)
    }
}

public struct FeedIncidentQueue: Equatable, Sendable, Codable {
    public var bytes: Int
    public var count: Int
    public var ageMilliseconds: Double
    public var incompleteAccessUnits: Int
    public var drops: Int

    public init(
        bytes: Int = 0,
        count: Int = 0,
        ageMilliseconds: Double = 0,
        incompleteAccessUnits: Int = 0,
        drops: Int = 0
    ) {
        self.bytes = max(0, bytes)
        self.count = max(0, count)
        self.ageMilliseconds = FeedIncidentPrivacy.rate(ageMilliseconds)
        self.incompleteAccessUnits = max(0, incompleteAccessUnits)
        self.drops = max(0, drops)
    }
}

public struct FeedIncidentDecoder: Equatable, Sendable, Codable {
    public var generation: Int
    public var formatGeneration: Int
    public var codec: String
    public var width: Int
    public var height: Int
    public var lastStatus: Int32?
    public var lastFlags: UInt32?
    public var origin: FeedDecoderErrorOrigin
    public var errorClass: String?
    /// The platform call that raised the last error (`FeedIncidentExport.decoderCalls`), else nil.
    public var errorCall: String?
    public var errorCount: Int
    public var decoderFailed: Bool
    public var errorAge: TimeInterval?
    public var receivedIrap: Bool
    public var awaitingIrap: Bool
    public var hasDecodableReferences: Bool
    public var lastIrapAge: TimeInterval?
    public var lastSuccessfulOutputAge: TimeInterval?
    public var rebuildReason: String?
    /// Bitstream facts behind the first decoder error of the current error episode.
    public var firstError: FeedIncidentDecodeErrorContext?

    public init(
        generation: Int = 0,
        formatGeneration: Int = 0,
        codec: String = "hevc",
        width: Int = 0,
        height: Int = 0,
        lastStatus: Int32? = nil,
        lastFlags: UInt32? = nil,
        origin: FeedDecoderErrorOrigin = .none,
        errorClass: String? = nil,
        errorCall: String? = nil,
        errorCount: Int = 0,
        decoderFailed: Bool = false,
        errorAge: TimeInterval? = nil,
        receivedIrap: Bool = false,
        awaitingIrap: Bool = false,
        hasDecodableReferences: Bool = true,
        lastIrapAge: TimeInterval? = nil,
        lastSuccessfulOutputAge: TimeInterval? = nil,
        rebuildReason: String? = nil,
        firstError: FeedIncidentDecodeErrorContext? = nil
    ) {
        self.generation = max(0, generation)
        self.formatGeneration = max(0, formatGeneration)
        self.codec = FeedIncidentPrivacy.token(codec, max: 16)
        self.width = max(0, width)
        self.height = max(0, height)
        self.lastStatus = lastStatus
        self.lastFlags = lastFlags
        self.origin = origin
        self.errorClass = errorClass.map { FeedIncidentPrivacy.token($0, max: 32) }
        self.errorCall = errorCall.map { FeedIncidentPrivacy.token($0, max: 32) }
        self.errorCount = max(0, errorCount)
        self.decoderFailed = decoderFailed
        self.errorAge = FeedIncidentPrivacy.age(errorAge)
        self.receivedIrap = receivedIrap
        self.awaitingIrap = awaitingIrap
        self.hasDecodableReferences = hasDecodableReferences
        self.lastIrapAge = FeedIncidentPrivacy.age(lastIrapAge)
        self.lastSuccessfulOutputAge = FeedIncidentPrivacy.age(lastSuccessfulOutputAge)
        self.rebuildReason = rebuildReason.map { FeedIncidentPrivacy.token($0) }
        self.firstError = firstError
    }
}

/// The access unit behind the first decoder error of an episode: NAL types in unit order, its
/// size, how long since the last accepted IRAP and the last parameter-set change, and the
/// access-unit rate over the second before it. Types, sizes, ages and rates only: no payload
/// bytes and no user data. Apple fills it from VideoToolbox callbacks; MediaCodec reports
/// failures per codec rather than per access unit, so Android producers leave it nil.
public struct FeedIncidentDecodeErrorContext: Equatable, Sendable, Codable {
    public var status: Int32
    public var nalTypes: [Int]
    public var accessUnitBytes: Int
    public var irapAge: TimeInterval?
    public var parameterSetChangeAge: TimeInterval?
    public var inputHz: Double

    public init(
        status: Int32,
        nalTypes: [Int],
        accessUnitBytes: Int,
        irapAge: TimeInterval? = nil,
        parameterSetChangeAge: TimeInterval? = nil,
        inputHz: Double = 0
    ) {
        self.status = status
        self.nalTypes = nalTypes.prefix(FeedIncidentDecodeErrorContext.maxNalTypes).map {
            min(max($0, 0), 63)
        }
        self.accessUnitBytes = max(0, accessUnitBytes)
        self.irapAge = FeedIncidentPrivacy.age(irapAge)
        self.parameterSetChangeAge = FeedIncidentPrivacy.age(parameterSetChangeAge)
        self.inputHz = FeedIncidentPrivacy.rate(inputHz)
    }

    public static let maxNalTypes = 16
}

public struct FeedIncidentLifecycle: Equatable, Sendable, Codable {
    public var foreground: Bool
    public var settingsCovered: Bool
    public var playbackActive: Bool
    public var connected: Bool
    public var liveEstablished: Bool
    public var thermalState: String
    public var memoryWarning: Bool
    public var lowPower: Bool
    public var sceneActive: Bool
    public var assistState: String
    public var outputObservable: Bool
    public var presentationExpected: Bool

    public init(
        foreground: Bool = true,
        settingsCovered: Bool = false,
        playbackActive: Bool = false,
        connected: Bool = false,
        liveEstablished: Bool = false,
        thermalState: String = "nominal",
        memoryWarning: Bool = false,
        lowPower: Bool = false,
        sceneActive: Bool = true,
        assistState: String = "off",
        outputObservable: Bool = true,
        presentationExpected: Bool = true
    ) {
        self.foreground = foreground
        self.settingsCovered = settingsCovered
        self.playbackActive = playbackActive
        self.connected = connected
        self.liveEstablished = liveEstablished
        self.thermalState = FeedIncidentPrivacy.token(thermalState, max: 16)
        self.memoryWarning = memoryWarning
        self.lowPower = lowPower
        self.sceneActive = sceneActive
        self.assistState = FeedIncidentPrivacy.token(assistState, max: 32)
        self.outputObservable = outputObservable
        self.presentationExpected = presentationExpected
    }
}

/// The feed watchdog's gating inputs at this sample, so a slow field recovery
/// shows what held the ladder. Each field is nil when the producer cannot see it.
/// `hold` is the watchdog's last quiet gate (`FeedWatchdog.Hold`) or the shell's
/// own pre-tick hold (`foregroundRecover`, `endpointRebuild`, `repairInFlight`).
public struct FeedIncidentWatchdogGate: Equatable, Sendable, Codable {
    public var pathReady: Bool?
    public var repairReady: Bool?
    public var outputExpected: Bool?
    public var hold: String?

    public init(
        pathReady: Bool? = nil, repairReady: Bool? = nil, outputExpected: Bool? = nil,
        hold: String? = nil
    ) {
        self.pathReady = pathReady
        self.repairReady = repairReady
        self.outputExpected = outputExpected
        self.hold = hold.map { FeedIncidentPrivacy.token($0, max: 32) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            pathReady: try values.decodeIfPresent(Bool.self, forKey: .pathReady),
            repairReady: try values.decodeIfPresent(Bool.self, forKey: .repairReady),
            outputExpected: try values.decodeIfPresent(Bool.self, forKey: .outputExpected),
            hold: try values.decodeIfPresent(String.self, forKey: .hold))
    }
}

extension FeedIncidentWatchdogGate {
    /// Every hold a producer records: `FeedWatchdog.Hold` raw values plus the shells' own pre-tick
    /// holds. Reporting exports anything else as `other`.
    public static let holdValues: Set<String> = [
        "fired", "notLive", "pathNotReady", "repairNotReady", "repairDeadline", "rejoinCooldown",
        "gopReset", "controlGrace", "receiveAlive", "outputNotExpected", "accessUnitStale",
        "firstVideoWait", "rungWait", "rebuildBackoff", "cooldown",
        "foregroundRecover", "endpointRebuild", "repairInFlight",
    ]
}

/// One-second allowlisted stage snapshot. No compressed payload, footage, or PII.
public struct FeedIncidentSnapshot: Equatable, Sendable, Codable {
    public var monotonicNow: TimeInterval
    public var wallClock: Date
    public var rates: FeedIncidentRates
    public var ages: FeedIncidentAges
    public var queue: FeedIncidentQueue
    public var decoder: FeedIncidentDecoder
    public var lifecycle: FeedIncidentLifecycle
    public var watchdogAction: String
    public var diagnoserFailure: String
    public var diagnoserRepair: String
    /// Absent on legacy records and producers without socket-level observation.
    public var ingress: FeedIncidentIngress?
    /// Absent on legacy records and producers without a feed watchdog.
    public var watchdogGate: FeedIncidentWatchdogGate?

    public init(
        monotonicNow: TimeInterval,
        wallClock: Date = Date(timeIntervalSince1970: 0),
        rates: FeedIncidentRates = FeedIncidentRates(),
        ages: FeedIncidentAges = FeedIncidentAges(),
        queue: FeedIncidentQueue = FeedIncidentQueue(),
        decoder: FeedIncidentDecoder = FeedIncidentDecoder(),
        lifecycle: FeedIncidentLifecycle = FeedIncidentLifecycle(),
        watchdogAction: String = "none",
        diagnoserFailure: String = "none",
        diagnoserRepair: String = "none"
    ) {
        self.monotonicNow = FeedIncidentPrivacy.stamp(monotonicNow)
        self.wallClock = wallClock
        self.rates = rates
        self.ages = ages
        self.queue = queue
        self.decoder = decoder
        self.lifecycle = lifecycle
        self.watchdogAction = FeedIncidentPrivacy.token(watchdogAction, max: 32)
        self.diagnoserFailure = FeedIncidentPrivacy.token(diagnoserFailure, max: 32)
        self.diagnoserRepair = FeedIncidentPrivacy.token(diagnoserRepair, max: 32)
        self.ingress = nil
        self.watchdogGate = nil
    }

    public init(
        monotonicNow: TimeInterval,
        wallClock: Date = Date(timeIntervalSince1970: 0),
        rates: FeedIncidentRates = FeedIncidentRates(),
        ages: FeedIncidentAges = FeedIncidentAges(),
        queue: FeedIncidentQueue = FeedIncidentQueue(),
        decoder: FeedIncidentDecoder = FeedIncidentDecoder(),
        lifecycle: FeedIncidentLifecycle = FeedIncidentLifecycle(),
        watchdogAction: String = "none",
        diagnoserFailure: String = "none",
        diagnoserRepair: String = "none",
        ingress: FeedIncidentIngress?,
        watchdogGate: FeedIncidentWatchdogGate? = nil
    ) {
        self.init(
            monotonicNow: monotonicNow, wallClock: wallClock, rates: rates,
            ages: ages, queue: queue, decoder: decoder, lifecycle: lifecycle,
            watchdogAction: watchdogAction, diagnoserFailure: diagnoserFailure,
            diagnoserRepair: diagnoserRepair)
        self.ingress = ingress
        self.watchdogGate = watchdogGate
    }
}

public struct FeedIncidentBreadcrumb: Equatable, Sendable, Codable {
    public var monotonicAt: TimeInterval
    public var kind: FeedIncidentBreadcrumbKind
    public var detail: String

    public init(
        monotonicAt: TimeInterval,
        kind: FeedIncidentBreadcrumbKind,
        detail: String = ""
    ) {
        self.monotonicAt = FeedIncidentPrivacy.stamp(monotonicAt)
        self.kind = kind
        self.detail = FeedIncidentPrivacy.token(detail, max: 32)
    }
}

/// Typed native SDK breadcrumb payload. Unknown values are dropped, not coerced.
public enum FeedIncidentNativeBreadcrumb: Sendable {
    public static let allowedValues: [String: Set<String>] = [
        "sceneState": ["active", "inactive"],
        "assistState": ["off", "identity", "replacement"],
        "path": ["unexpectedDisconnect", "bleDroppedVideoLive"],
        "repairPhase": [
            "requested", "blocked", "locallySent", "peerResponse", "pictureRestored",
        ],
        "repairAction": ["decoder", "enable", "session", "endpoint", "rejoin"],
        // Producers' reasons: RecoveryReason wires (Kotlin media), SessionRecoveryTrigger cases and
        // the DJI shells' decoder and enable gates. Kotlin twin: the same set.
        "repairReason": [
            "bleDropped", "softAPLost", "datalinkLost", "operatorRetry", "feedWatchdogStall",
            "commandTimeout", "firstPicture", "outputSilence", "referenceLoss", "notReady",
            "overlap",
            "playback", "path", "serialGate", "media", "watchdog", "pictureDeadline",
            "outputResumed",
            "udpAlive", "keyframeUnanswered", "videoLive", "presentationOnly", "decoderNotReady",
            "pathNotReady", "cooldown", "enableGate",
        ],
    ]

    /// `value` when the `key` vocabulary holds it, else `other`: free text never leaves the phone.
    public static func closed(_ key: String, _ value: String) -> String {
        allowedValues[key]?.contains(value) == true ? value : "other"
    }

    public static func isAllowedMessage(_ message: String) -> Bool {
        FeedIncidentBreadcrumbKind(rawValue: message) != nil || message == "repair"
    }

    public static func details(kind: FeedIncidentBreadcrumbKind, detail: String) -> [String: String]
    {
        switch kind {
        case .sceneActivity:
            return sanitized(["sceneState": detail])
        case .assistChange:
            return sanitized(["assistState": detail])
        case .pathChange:
            return sanitized(["path": detail])
        case .settingsEnter, .settingsExit, .surfaceAttach, .surfaceDetach,
            .decoderCreate, .decoderInvalidate, .cameraCommand:
            return [:]
        }
    }

    public static func details(repair: FeedRepairRecord) -> [String: String] {
        sanitized([
            "repairPhase": repair.phase.rawValue,
            "repairAction": repair.action,
        ])
    }

    public static func sanitized(_ raw: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in raw {
            let token = FeedIncidentPrivacy.token(value, max: 32)
            guard let allowed = allowedValues[key], allowed.contains(token) else { continue }
            out[key] = token
        }
        return out
    }
}

public struct FeedRepairRecord: Equatable, Sendable, Codable {
    /// Reason on a first-picture `0x09/0xa8` resend. Recorded, never credited.
    public static let firstPictureReason = "firstPicture"

    public var monotonicAt: TimeInterval
    public var action: String
    public var phase: FeedRepairPhase
    public var reason: String?

    public init(
        monotonicAt: TimeInterval,
        action: String,
        phase: FeedRepairPhase,
        reason: String? = nil
    ) {
        self.monotonicAt = FeedIncidentPrivacy.stamp(monotonicAt)
        // Producers pass free text (a blocked enable's detail, a trigger's description), and the
        // record reaches reports as trigger and recoveredBy: only the closed vocabulary is kept.
        self.action = FeedIncidentNativeBreadcrumb.closed(
            "repairAction", FeedIncidentPrivacy.token(action, max: 32))
        self.phase = phase
        self.reason = reason.map {
            FeedIncidentNativeBreadcrumb.closed(
                "repairReason", FeedIncidentPrivacy.token($0, max: 32))
        }
    }

    /// A caller can mutate public fields after construction; close again at reporting boundaries.
    public func closed() -> FeedRepairRecord {
        FeedRepairRecord(monotonicAt: monotonicAt, action: action, phase: phase, reason: reason)
    }

    /// A stored record (an older build's spool included) is closed like a new one.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            monotonicAt: try container.decode(TimeInterval.self, forKey: .monotonicAt),
            action: try container.decode(String.self, forKey: .action),
            phase: try container.decode(FeedRepairPhase.self, forKey: .phase),
            reason: try container.decodeIfPresent(String.self, forKey: .reason))
    }
}

public struct FeedIncidentErrorCount: Equatable, Sendable, Codable {
    public var errorClass: String
    public var count: Int

    public init(errorClass: String, count: Int) {
        self.errorClass = FeedIncidentPrivacy.token(errorClass, max: 32)
        self.count = max(0, count)
    }
}

public struct FeedIncidentHeader: Equatable, Sendable, Codable {
    public var schemaVersion: Int
    public var incidentID: String
    public var sessionID: String
    public var kind: FeedIncidentKind
    public var failingStage: FeedIncidentFailingStage
    public var errorClass: String?
    public var outcome: FeedIncidentOutcome
    public var startedAtWallClock: Date
    public var startedAtMonotonic: TimeInterval
    public var endedAtMonotonic: TimeInterval?
    public var firstFailureAt: TimeInterval
    public var worstGapSeconds: TimeInterval
    public var appVersion: String
    public var appBuild: String
    public var sourceRevision: String
    public var osName: String
    public var osVersion: String
    public var hardwareClass: String
    public var cameraFamily: String
    public var cameraFirmware: String?
    public var decoderGeneration: Int
    public var socketGeneration: Int
    public var evictions: Int
    public var assistState: String
    public var healthyExposureSeconds: TimeInterval
    /// Absent on legacy bundles. Do not fill from the current process.
    public var testSource: FeedIncidentTestSource? = nil
    public var buildIdentity: String? = nil

    public var processInterrupted: Bool { outcome == .interrupted }

    public var resolvedTestSource: FeedIncidentTestSource { testSource ?? .unknown }

    public var resolvedBuildIdentity: String { FeedIncidentBuildIdentity.parse(buildIdentity) }
}

public struct FeedIncidentBundle: Equatable, Sendable, Codable {
    public var header: FeedIncidentHeader
    public var prelude: [FeedIncidentSnapshot]
    public var during: [FeedIncidentSnapshot]
    public var aftermath: [FeedIncidentSnapshot]
    public var breadcrumbs: [FeedIncidentBreadcrumb]
    public var repairs: [FeedRepairRecord]
    public var aggregatedErrors: [FeedIncidentErrorCount]
}

/// One session's healthy exposure and incident count, kept even when the session had no dropout
/// (the denominator for incident rates). Apps persist it with `FeedSessionSummaryStore`.
public struct FeedIncidentSessionSummary: Equatable, Sendable, Codable {
    public var sessionID: String
    public var healthyExposureSeconds: Double
    public var incidentCount: Int
    public var outcome: String
    public var sourceRevision: String
    public var recordedAt: Date?
    public var appVersion: String?
    public var appBuild: String?
    public var testSource: FeedIncidentTestSource?
    public var buildIdentity: String?

    public init(
        sessionID: String, healthyExposureSeconds: Double, incidentCount: Int, outcome: String,
        sourceRevision: String, recordedAt: Date? = Date(), appVersion: String? = nil,
        appBuild: String? = nil, testSource: FeedIncidentTestSource? = nil,
        buildIdentity: String? = nil
    ) {
        self.sessionID = sessionID
        self.healthyExposureSeconds = healthyExposureSeconds
        self.incidentCount = incidentCount
        self.outcome = outcome
        self.sourceRevision = sourceRevision
        self.recordedAt = recordedAt
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.testSource = testSource
        self.buildIdentity = buildIdentity
    }
}

/// Stable grouping keys for a future vendor event. Not an SDK payload.
public struct FeedIncidentGrouping: Equatable, Sendable, Codable {
    public var schemaVersion: Int
    public var failingStage: String
    public var errorClass: String
    public var outcome: String
    public var release: String
    public var os: String
    public var hardwareClass: String
    public var cameraFirmware: String
    public var assistState: String
}

public struct FeedIncidentVendorEnvelope: Equatable, Sendable, Codable {
    public var schemaVersion: Int
    public var eventName: String
    public var grouping: FeedIncidentGrouping
    public var incidentID: String
    public var sessionID: String
    public var kind: String
    public var worstGapSeconds: TimeInterval
    public var healthyExposureSeconds: TimeInterval
    public var decoderGeneration: Int
    public var socketGeneration: Int
    public var testSource: String
    public var buildIdentity: String
    /// First repair reason recorded during this incident (`bleDropped`, …).
    public var trigger: String
    /// Last repair action before a recovered outcome, else `none`.
    public var recoveredBy: String
    /// The decoder call behind `grouping.errorClass` (`FeedIncidentExport.decoderCalls`), else `none`.
    public var decoderCall: String = "none"
    /// `awaiting` when the decoder held for a keyframe (IRAP) as the incident opened, else `none`.
    public var keyframeWait: String = "unknown"
    /// Age of the last accepted IRAP at onset, bucketed (`FeedIncidentExport.irapAgeBucket`).
    public var irapAge: String = "unknown"
    /// Decoder submits against accepts at onset (`FeedIncidentExport.decodeFlow`).
    public var decodeFlow: String = "unknown"
    /// Diagnostic: `yes` when any snapshot of the incident was taken off screen (not foreground
    /// or scene inactive) or a scene-inactive breadcrumb falls inside it, `no` when neither,
    /// `unknown` without a snapshot. Kotlin twin.
    public var background: String = "unknown"
    /// Diagnostic: whether the decoder still waited for an IRAP at the incident's newest
    /// snapshot (`yes`/`no`/`unknown`). Kotlin twin.
    public var awaitingIrap: String = "unknown"
    /// The episode's first decoder error status (VideoToolbox `OSStatus`), else the last
    /// non-zero one, as decimal digits; `none` when the decoder reported no error.
    public var decoderStatus: String = "none"
    /// The live codec during the incident: `avc`, `hevc`, `unknown` or `other`.
    public var decoderCodec: String = "unknown"
    /// The feed watchdog's last hold during the incident (`FeedWatchdog.Hold`), else `none`.
    public var watchdogHold: String = "none"
}

extension FeedIncidentVendorEnvelope {
    /// Envelopes written before the decode-state, decoder and watchdog fields read them as unknown.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        eventName = try values.decode(String.self, forKey: .eventName)
        grouping = try values.decode(FeedIncidentGrouping.self, forKey: .grouping)
        incidentID = try values.decode(String.self, forKey: .incidentID)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        kind = try values.decode(String.self, forKey: .kind)
        worstGapSeconds = try values.decode(TimeInterval.self, forKey: .worstGapSeconds)
        healthyExposureSeconds = try values.decode(
            TimeInterval.self, forKey: .healthyExposureSeconds)
        decoderGeneration = try values.decode(Int.self, forKey: .decoderGeneration)
        socketGeneration = try values.decode(Int.self, forKey: .socketGeneration)
        testSource = try values.decode(String.self, forKey: .testSource)
        buildIdentity = try values.decode(String.self, forKey: .buildIdentity)
        trigger = try values.decode(String.self, forKey: .trigger)
        recoveredBy = try values.decode(String.self, forKey: .recoveredBy)
        decoderCall = try values.decodeIfPresent(String.self, forKey: .decoderCall) ?? "none"
        keyframeWait = try values.decodeIfPresent(String.self, forKey: .keyframeWait) ?? "unknown"
        irapAge = try values.decodeIfPresent(String.self, forKey: .irapAge) ?? "unknown"
        decodeFlow = try values.decodeIfPresent(String.self, forKey: .decodeFlow) ?? "unknown"
        background = try values.decodeIfPresent(String.self, forKey: .background) ?? "unknown"
        awaitingIrap = try values.decodeIfPresent(String.self, forKey: .awaitingIrap) ?? "unknown"
        decoderStatus = try values.decodeIfPresent(String.self, forKey: .decoderStatus) ?? "none"
        decoderCodec = try values.decodeIfPresent(String.self, forKey: .decoderCodec) ?? "unknown"
        watchdogHold = try values.decodeIfPresent(String.self, forKey: .watchdogHold) ?? "none"
    }
}

public struct FeedIncidentVerdict: Equatable, Sendable {
    public var suppression: FeedIncidentSuppression
    public var kind: FeedIncidentKind?
    public var failingStage: FeedIncidentFailingStage?

    public var shouldRecord: Bool {
        suppression == .none && kind != nil && failingStage != nil
    }
}

/// Classifies an established-feed stall from allowlisted stage counters.
public enum FeedIncidentClassifier: Sendable {
    public static func suppression(of snapshot: FeedIncidentSnapshot) -> FeedIncidentSuppression? {
        let life = snapshot.lifecycle
        if life.playbackActive { return .playback }
        if !life.connected { return .disconnected }
        if !life.foreground || !life.sceneActive { return .background }
        if !life.liveEstablished { return .neverEstablished }
        return nil
    }

    public static func classify(_ snapshot: FeedIncidentSnapshot) -> FeedIncidentVerdict {
        if let suppression = suppression(of: snapshot) {
            return FeedIncidentVerdict(suppression: suppression, kind: nil, failingStage: nil)
        }

        let life = snapshot.lifecycle
        let threshold = FeedIncidentBounds.stallThreshold
        let packetFresh =
            FeedIncidentPrivacy.isFresh(snapshot.ages.packetAge, threshold: threshold)
            || snapshot.rates.packetHz >= 1
        let auFresh =
            FeedIncidentPrivacy.isFresh(snapshot.ages.accessUnitAge, threshold: threshold)
            || snapshot.rates.accessUnitHz >= 1
        let inputFresh = packetFresh || auFresh
        let outputStale =
            life.outputObservable
            && FeedIncidentPrivacy.isStale(
                age: snapshot.ages.decodedOutputAge,
                hertz: snapshot.rates.decodedOutputHz,
                flowingAlternative: snapshot.rates.decodeSubmitHz >= 1 || inputFresh,
                threshold: threshold)
        let outputFresh =
            life.outputObservable
            && FeedIncidentPrivacy.isFresh(snapshot.ages.decodedOutputAge, threshold: threshold)
        let presentStale =
            life.presentationExpected
            && FeedIncidentPrivacy.isStale(
                age: snapshot.ages.presentAge,
                hertz: snapshot.rates.presentHz,
                flowingAlternative: true,
                threshold: threshold)
        let assistStale = FeedIncidentPrivacy.isStale(
            age: snapshot.ages.assistOutputAge,
            hertz: snapshot.rates.assistOutputHz,
            flowingAlternative: outputFresh,
            threshold: threshold)

        let acceptStale = FeedIncidentPrivacy.isStale(
            age: snapshot.ages.decodeAcceptAge,
            hertz: snapshot.rates.decodeAcceptHz,
            flowingAlternative: snapshot.rates.decodeSubmitHz >= 1,
            threshold: threshold)
        let decodeStage: FeedIncidentFailingStage =
            acceptStale && snapshot.rates.decodeSubmitHz >= 1 ? .decodeAccept : .decodedOutput
        if life.outputObservable && outputStale {
            let currentError = isCurrentDecoderFailure(snapshot.decoder)
            let stage = decodeStage
            let kind: FeedIncidentKind
            if currentError {
                kind = .decoderError
            } else if inputFresh {
                kind = .freshInputStaleOutput
            } else {
                kind = .transportStall
            }
            return FeedIncidentVerdict(suppression: .none, kind: kind, failingStage: stage)
        }
        // A compressed-layer feed can retain timestamps from an earlier
        // native assist pipeline. Its stopped clock is not an active stall.
        if outputFresh && assistStale
            && snapshot.ages.assistOutputAge != nil
        {
            return FeedIncidentVerdict(
                suppression: .none, kind: .assistStalled, failingStage: .assistOutput)
        }
        // An unobservable decode path does not make the presenter the stage that stopped.
        // A current native failure (OPENPOCKETCINE-IOS-2E: -12903 after the scene went
        // inactive) is a decoder error, and input that stopped arriving is a transport stall.
        if !life.outputObservable && presentStale {
            if isCurrentDecoderFailure(snapshot.decoder) {
                return FeedIncidentVerdict(
                    suppression: .none, kind: .decoderError, failingStage: decodeStage)
            }
            if !inputFresh {
                return FeedIncidentVerdict(
                    suppression: .none, kind: .transportStall,
                    failingStage: packetFresh ? .accessUnit : .packet)
            }
        }
        if (outputFresh || !life.outputObservable) && presentStale {
            return FeedIncidentVerdict(
                suppression: .none, kind: .presentStalled, failingStage: .presentation)
        }
        if !inputFresh {
            if life.outputObservable && outputFresh {
                return FeedIncidentVerdict(suppression: .none, kind: nil, failingStage: nil)
            }
            if !life.outputObservable && life.presentationExpected
                && FeedIncidentPrivacy.isFresh(snapshot.ages.presentAge, threshold: threshold)
            {
                return FeedIncidentVerdict(suppression: .none, kind: nil, failingStage: nil)
            }
            return FeedIncidentVerdict(
                suppression: .none, kind: .transportStall,
                failingStage: packetFresh ? .accessUnit : .packet)
        }
        return FeedIncidentVerdict(suppression: .none, kind: nil, failingStage: nil)
    }

    /// Fresh decoded output and presentation, with no active assist failure.
    /// A generation change or repair request is not recovery.
    public static func isRecovered(_ snapshot: FeedIncidentSnapshot) -> Bool {
        if suppression(of: snapshot) != nil { return false }
        guard classify(snapshot).kind == nil else { return false }
        let life = snapshot.lifecycle
        let threshold = FeedIncidentBounds.stallThreshold
        // With neither downstream stage observable, receipt of compressed
        // packets cannot prove picture recovery or healthy live exposure.
        guard life.outputObservable || life.presentationExpected else { return false }
        if life.outputObservable {
            guard
                FeedIncidentPrivacy.isFresh(
                    snapshot.ages.decodedOutputAge, threshold: threshold)
            else { return false }
        }
        if life.presentationExpected {
            guard
                FeedIncidentPrivacy.isFresh(snapshot.ages.presentAge, threshold: threshold)
            else { return false }
        }
        return true
    }

    public static func isCurrentDecoderFailure(_ decoder: FeedIncidentDecoder) -> Bool {
        if decoder.decoderFailed { return true }
        guard let errorAge = decoder.errorAge else { return false }
        if let success = decoder.lastSuccessfulOutputAge {
            return errorAge < success
        }
        return true
    }
}

public enum FeedIncidentFileNaming: Sendable {
    public static func incident(id: String) -> String {
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "incident-\(safe.isEmpty ? "unknown" : safe).json"
    }

    public static func metricKit(
        kind: String, deliveredAt: Date, deliveryID: UUID, index: Int
    ) -> String {
        let safeKind = kind.filter { $0.isLetter || $0.isNumber }
        let kindName = safeKind.isEmpty ? "payload" : safeKind
        let millis = Int((deliveredAt.timeIntervalSince1970 * 1_000).rounded())
        return "metrickit-\(kindName)-\(millis)-\(deliveryID.uuidString)-\(max(0, index)).json"
    }
}

enum FeedIncidentPrivacy {
    static func token(_ raw: String, max: Int = FeedIncidentBounds.stringLength) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = String(trimmed.prefix(max))
        return PrivacyRedactor.redact(clipped)
    }

    static func rate(_ value: Double) -> Double {
        guard value.isFinite, value >= 0 else { return 0 }
        return value
    }

    static func stamp(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value >= 0 else { return 0 }
        return value
    }

    static func age(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func isFresh(_ age: TimeInterval?, threshold: TimeInterval) -> Bool {
        guard let age else { return false }
        return age < threshold
    }

    static func isStale(
        age: TimeInterval?,
        hertz: Double,
        flowingAlternative: Bool,
        threshold: TimeInterval
    ) -> Bool {
        if let age { return age >= threshold }
        return hertz == 0 && flowingAlternative
    }

    static func gapSeconds(for snapshot: FeedIncidentSnapshot, stage: FeedIncidentFailingStage)
        -> TimeInterval
    {
        let ages = snapshot.ages
        let chosen: TimeInterval?
        switch stage {
        case .packet: chosen = ages.packetAge
        case .accessUnit: chosen = ages.accessUnitAge
        case .decodeAccept: chosen = ages.decodeAcceptAge
        case .decodedOutput: chosen = ages.decodedOutputAge
        case .assistOutput: chosen = ages.assistOutputAge
        case .presentation: chosen = ages.presentAge
        }
        return age(chosen) ?? 0
    }
}

/// The spool's JSON shape; app-owned stores read and write bundles with it.
public enum FeedIncidentCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
