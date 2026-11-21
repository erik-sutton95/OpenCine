import Foundation

// The live stream surface as values: the settings card, the Go live control, the status readout,
// notices and warnings. Views take these and actions only; they never import the streaming engine.
// Every string is in `LiveStreamCopy` and in `docs/streaming/ui-contract.md`, which the Compose
// twin (`monitor-ui`) mirrors. Service names arrive as values from the engine's preset table.

/// One service in the picker, built by the composition layer from the engine's preset table.
public struct LiveStreamServiceOption: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// One sentence on where to find the stream key.
    public var keyHint: String
    /// The operator enters the server address (it is issued with the key).
    public var needsServer: Bool
    /// The entered server may be plain `rtmp://` (a Custom server only).
    public var acceptsPlainServer: Bool
    /// The service takes a vertical 9:16 picture.
    public var vertical: Bool

    public init(
        id: String, name: String, keyHint: String, needsServer: Bool, acceptsPlainServer: Bool, vertical: Bool
    ) {
        self.id = id
        self.name = name
        self.keyHint = keyHint
        self.needsServer = needsServer
        self.acceptsPlainServer = acceptsPlainServer
        self.vertical = vertical
    }
}

/// Whether a key is saved. Never the key itself. `unavailable` is a locked keychain or keystore:
/// it is not `absent`, so the card never offers to save over a key it cannot read.
public enum LiveStreamKeyState: Hashable, Sendable {
    case absent, saved, unavailable
}

/// Whether the connection lets the device reach the internet while it reaches the camera. A host
/// capability value: USB-C, HDMI capture, a shared Wi-Fi network and the device's own hotspot are
/// `allowed`; the camera's own Wi-Fi is not. No camera (or an unknown route) is `noCamera`.
public enum LiveStreamEligibility: Hashable, Sendable {
    case allowed, cameraWiFi, noCamera

    public var allowsGoLive: Bool { self == .allowed }

    /// The control's caption.
    public var shortReason: String? {
        switch self {
        case .allowed: nil
        case .cameraWiFi: "Camera Wi-Fi has no internet"
        case .noCamera: "No camera"
        }
    }

    /// The settings note and the control's accessibility hint: why, and what to change.
    public var reason: String? {
        switch self {
        case .allowed: nil
        case .cameraWiFi:
            "This phone is on the camera's own Wi-Fi, which has no internet. To go live, connect the camera "
                + "over a shared Wi-Fi network, this phone's hotspot or a cable."
        case .noCamera: "Connect a camera to go live."
        }
    }
}

/// Where the stream's picture size comes from.
public enum LiveStreamQualityKind: Hashable, Sendable {
    /// The camera picture at its own size.
    case source
    /// The camera picture scaled up: always named as upscaled.
    case upscaled
    /// The camera's own encoded picture, relayed: standard color, no LUT.
    case camera
}

/// The stream's fixed output, set at go-live.
public struct LiveStreamQuality: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var framesPerSecond: Double
    public var videoBitrateBps: Int
    public var kind: LiveStreamQualityKind

    public init(
        width: Int, height: Int, framesPerSecond: Double, videoBitrateBps: Int, kind: LiveStreamQualityKind = .source
    ) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.videoBitrateBps = videoBitrateBps
        self.kind = kind
    }

    public var isVertical: Bool { height > width }

    /// `720p, 30 fps, 3 Mbps`; a vertical output names its short side: `720p vertical, ...`; an
    /// upscaled output says so: `1080p upscaled, ...`.
    public var line: String {
        let suffix = switch kind {
        case .source: ""
        case .upscaled: " upscaled"
        case .camera: " from camera"
        }
        let size = "\(min(width, height))p" + (isVertical ? " vertical" : "") + suffix
        return "\(size), \(LiveStreamCopy.number(framesPerSecond, decimals: 2)) fps, "
            + LiveStreamCopy.bitrate(videoBitrateBps)
    }
}

/// Why a stream ended.
public enum LiveStreamEnd: Hashable, Sendable {
    /// The operator stopped it. No notice.
    case stopped
    /// The server refused the stream; the reason holds no key.
    case refused(reason: String)
    /// The network did not come back within the reconnect window.
    case gaveUp
    /// The first connection failed before the stream ever went live.
    case unreachable
    /// The app left the screen.
    case background
    /// Microphone access is off.
    case microphoneDenied
    /// The camera did not start publishing its own stream, after one retry.
    case cameraDidNotStart
    /// The camera stopped answering while it was asked to start or end its own stream.
    case cameraNotResponding

    public var notice: String? {
        switch self {
        case .stopped: nil
        case .refused(let reason): "The service refused the stream: \(reason). Check the stream key and server."
        case .gaveUp: "The stream ended: the network did not come back within 2 minutes."
        case .unreachable:
            "Could not reach the streaming server. Check this phone's internet connection, then go live again."
        case .background: "The stream ended when the app left the screen."
        case .microphoneDenied: "Allow microphone access in Settings to go live."
        case .cameraDidNotStart:
            "The camera did not start its stream. Try again, or choose Camera feed in the live stream settings."
        case .cameraNotResponding:
            "The camera stopped responding. Hold its power button about 10 seconds to restart it, then go live again."
        }
    }

    /// Only a stream the app ended by leaving the screen offers one tap restart.
    public var offersRestart: Bool { self == .background }
}

public enum LiveStreamPhase: Hashable, Sendable {
    case idle, connecting, live
    case reconnecting(attempt: Int)
    case ended(LiveStreamEnd)

    /// Connecting, live or reconnecting: a stream is running and can be stopped.
    public var isRunning: Bool {
        switch self {
        case .connecting, .live, .reconnecting: true
        case .idle, .ended: false
        }
    }
}

public enum LiveStreamHealth: Hashable, Sendable {
    case good, congested, offline
}

/// The status readout while a stream runs.
public struct LiveStreamStatusState: Hashable, Sendable {
    public var phase: LiveStreamPhase
    public var elapsedSeconds: Int
    public var sentBitrateBps: Int
    /// Whole video groups the send queue dropped on a slow network.
    public var droppedGroups: Int
    public var health: LiveStreamHealth

    public init(phase: LiveStreamPhase, elapsedSeconds: Int, sentBitrateBps: Int, droppedGroups: Int,
        health: LiveStreamHealth) {
        self.phase = phase
        self.elapsedSeconds = elapsedSeconds
        self.sentBitrateBps = sentBitrateBps
        self.droppedGroups = droppedGroups
        self.health = health
    }

    public var elapsedText: String { LiveStreamCopy.elapsed(elapsedSeconds) }
    public var bitrateText: String { LiveStreamCopy.bitrate(sentBitrateBps) }
    public var droppedText: String { "Dropped \(droppedGroups)" }
    public var healthText: String {
        switch health {
        case .good: "Good"
        case .congested: "Slow network"
        case .offline: "Offline"
        }
    }

    public var accessibilityLabel: String {
        let connection = switch health {
        case .good: "good"
        case .congested: "slow"
        case .offline: "offline"
        }
        return "Streaming for \(LiveStreamCopy.spokenElapsed(elapsedSeconds)). "
            + "Sending \(LiveStreamCopy.spokenBitrate(sentBitrateBps)). \(droppedGroups) dropped. "
            + "Connection \(connection)."
    }
}

/// While the stream carries the camera's own picture: one line under the Go live control.
public enum LiveStreamCameraStatus: Hashable, Sendable, CaseIterable {
    case starting, live, recovering, lost, notResponding

    public var text: String {
        switch self {
        case .starting: "Starting the camera's stream."
        case .live: "1080p from camera. Assists, scopes and camera controls are off in this mode."
        case .recovering: "The camera's stream stopped. Trying again."
        case .lost: "The camera's stream did not come back."
        case .notResponding: "The camera is not responding. Hold its power button about 10 seconds to restart it."
        }
    }

    /// The operator may ask the camera to start again (the outgoing stream stays up meanwhile).
    public var offersRetry: Bool { self == .lost || self == .notResponding }
}

/// A shared network the camera can join for its own stream, offered when there are several.
public struct LiveStreamNetworkChoice: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A warning while live. The stream never stops for one.
public enum LiveStreamWarning: Hashable, Sendable {
    case hot, lowBattery

    public var text: String {
        switch self {
        case .hot: "The phone is hot. The stream continues; give it air or shade."
        case .lowBattery: "Battery is low. The stream continues until the phone stops it."
        }
    }
}

/// A server address or key the engine refused, as the card words it.
public enum LiveStreamProblem: Hashable, Sendable {
    case notRTMPS(plainAllowed: Bool)
    case invalidServer
    case emptyKey
    case keyLooksLikeURL

    public var text: String {
        switch self {
        case .notRTMPS(let plainAllowed):
            plainAllowed ? "Use an rtmps:// or rtmp:// address." : "Use the rtmps:// address the service gave you."
        case .invalidServer: "The address needs a host and a path, like rtmps://live.example.com/app."
        case .emptyKey: "Paste the stream key."
        case .keyLooksLikeURL: "That looks like an address, not a key. Put the address in Server and the key here."
        }
    }
}

/// The Go live control over the monitor.
public struct LiveStreamControlState: Hashable, Sendable {
    public enum Tap: Hashable, Sendable {
        case confirmStart, confirmStop
    }

    public enum Tone: Hashable, Sendable {
        case ready, unavailable, live, warning
    }

    public var title: String
    public var isEnabled: Bool
    /// Under the control: the short reason it is unavailable.
    public var caption: String?
    public var accessibilityLabel: String
    public var accessibilityHint: String
    /// What a tap opens; `nil` when disabled.
    public var tap: Tap?
    public var tone: Tone

    public init(phase: LiveStreamPhase, eligibility: LiveStreamEligibility, serviceName: String, elapsedSeconds: Int) {
        switch phase {
        case .idle, .ended:
            title = "Go live"
            if eligibility.allowsGoLive {
                isEnabled = true
                caption = nil
                accessibilityLabel = "Go live"
                accessibilityHint = "Starts streaming to \(serviceName)"
                tap = .confirmStart
                tone = .ready
            } else {
                isEnabled = false
                caption = eligibility.shortReason
                accessibilityLabel = "Go live, unavailable"
                accessibilityHint = eligibility.reason ?? ""
                tap = nil
                tone = .unavailable
            }
            return
        case .connecting:
            title = "Connecting"
            accessibilityLabel = "Connecting to \(serviceName)"
            tone = .warning
        case .live:
            title = "LIVE \(LiveStreamCopy.elapsed(elapsedSeconds))"
            accessibilityLabel = "Live for \(LiveStreamCopy.spokenElapsed(elapsedSeconds))"
            tone = .live
        case .reconnecting(let attempt):
            title = "Reconnecting"
            accessibilityLabel = "Reconnecting, attempt \(attempt)"
            tone = .warning
        }
        isEnabled = true
        caption = nil
        accessibilityHint = "Ends the stream"
        tap = .confirmStop
    }
}

/// Everything the monitor shows about a live stream, as values.
public struct LiveStreamMonitorState: Hashable, Sendable {
    public var control: LiveStreamControlState
    /// The service the stream goes to, for the confirmation.
    public var serviceName: String
    public var quality: LiveStreamQuality?
    /// `false` for a plain `rtmp://` server: the start confirmation says so.
    public var encrypted: Bool
    /// While connecting, live or reconnecting.
    public var status: LiveStreamStatusState?
    /// Why the last stream ended, when it ended for a reason other than the operator's stop.
    public var end: LiveStreamEnd?
    public var warning: LiveStreamWarning?
    /// While the stream carries the camera's own picture.
    public var cameraStatus: LiveStreamCameraStatus?
    /// With two or more, the start confirmation offers one button per network, hotspot first.
    public var networkChoices: [LiveStreamNetworkChoice]

    public init(control: LiveStreamControlState, serviceName: String, quality: LiveStreamQuality?, encrypted: Bool,
        status: LiveStreamStatusState?, end: LiveStreamEnd?, warning: LiveStreamWarning?,
        cameraStatus: LiveStreamCameraStatus? = nil, networkChoices: [LiveStreamNetworkChoice] = []) {
        self.cameraStatus = cameraStatus
        self.networkChoices = networkChoices
        self.control = control
        self.serviceName = serviceName
        self.quality = quality
        self.encrypted = encrypted
        self.status = status
        self.end = end
        self.warning = warning
    }
}

/// The small app-level pill while a stream runs and no monitor shows the Go live control (the
/// monitor closed after the camera was lost, or a Multiview stage opened). It reads like the
/// running control and offers only Stop, behind the same one stop confirmation.
public struct LiveStreamPillState: Hashable, Sendable {
    public var title: String
    public var tone: LiveStreamControlState.Tone
    public var accessibilityLabel: String
    public var serviceName: String

    public init(phase: LiveStreamPhase, serviceName: String, elapsedSeconds: Int) {
        let control = LiveStreamControlState(phase: phase, eligibility: .allowed, serviceName: serviceName,
            elapsedSeconds: elapsedSeconds)
        title = control.title
        tone = control.tone
        self.serviceName = serviceName
        accessibilityLabel = switch phase {
        case .live: "Live on \(serviceName) for \(LiveStreamCopy.spokenElapsed(elapsedSeconds))"
        case .reconnecting(let attempt): "Reconnecting to \(serviceName), attempt \(attempt)"
        case .connecting, .idle, .ended: "Connecting to \(serviceName)"
        }
    }

    public var stopTitle: String { LiveStreamCopy.pillStop }
    public var stopAccessibilityLabel: String { "Stop the stream to \(serviceName)" }
}

/// One Quality choice on the settings card. An unavailable choice is listed but cannot be chosen;
/// its reason shows under the row.
public struct LiveStreamQualityOption: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// One line under the row while this choice is selected.
    public var detail: String?
    public var unavailableReason: String?

    public init(id: String, title: String, detail: String? = nil, unavailableReason: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.unavailableReason = unavailableReason
    }

    public var isEnabled: Bool { unavailableReason == nil }
}

/// The settings card's values.
public struct LiveStreamSettingsState: Hashable, Sendable {
    public var services: [LiveStreamServiceOption]
    public var selectedID: String
    /// The entered server, for services that need one.
    public var server: String
    public var key: LiveStreamKeyState
    /// The output a stream would use now, or `nil` before a camera is connected.
    public var quality: LiveStreamQuality?
    /// The connected source's picture height, for the vertical note.
    public var sourceHeight: Int?
    public var eligibility: LiveStreamEligibility
    public var showOnMonitor: Bool
    public var phase: LiveStreamPhase
    /// The last Save's refusal.
    public var problem: LiveStreamProblem?
    /// The Quality choices for the connected source; a picker shows with two or more.
    public var qualityOptions: [LiveStreamQualityOption]
    public var selectedQualityID: String

    public init(
        services: [LiveStreamServiceOption], selectedID: String, server: String, key: LiveStreamKeyState,
        quality: LiveStreamQuality?, sourceHeight: Int?, eligibility: LiveStreamEligibility, showOnMonitor: Bool,
        phase: LiveStreamPhase, problem: LiveStreamProblem? = nil, qualityOptions: [LiveStreamQualityOption] = [],
        selectedQualityID: String = "cameraFeed"
    ) {
        self.qualityOptions = qualityOptions
        self.selectedQualityID = selectedQualityID
        self.services = services
        self.selectedID = selectedID
        self.server = server
        self.key = key
        self.quality = quality
        self.sourceHeight = sourceHeight
        self.eligibility = eligibility
        self.showOnMonitor = showOnMonitor
        self.phase = phase
        self.problem = problem
    }

    public var selected: LiveStreamServiceOption? { services.first { $0.id == selectedID } ?? services.first }
    public var showsServer: Bool { selected?.needsServer ?? false }
    public var serverPlaceholder: String {
        selected?.acceptsPlainServer == true ? "rtmps:// or rtmp://" : "rtmps://"
    }
    public var showsPlainWarning: Bool {
        guard let selected, selected.needsServer, selected.acceptsPlainServer else { return false }
        return server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("rtmp://")
    }
    public var plainWarning: String { LiveStreamCopy.plainWarning }
    /// Service, server and key are locked while a stream runs.
    public var isLocked: Bool { phase.isRunning }
    public var offersKeyEntry: Bool { key == .absent }
    public var offersKeyRemoval: Bool { key == .saved }
    public var keyValueText: String? { key == .saved ? "Saved" : nil }
    public var keyUnavailableNote: String? { key == .unavailable ? "Unlock this phone to read the saved key." : nil }
    public var qualityLine: String { quality?.line ?? "Set from the camera when you go live." }
    public var showsQualityPicker: Bool { qualityOptions.count > 1 }
    public var selectedQuality: LiveStreamQualityOption? { qualityOptions.first { $0.id == selectedQualityID } }
    /// Under the Quality row: why the selected choice is unavailable, or its one-line detail.
    public var qualityDetail: String? { selectedQuality.flatMap { $0.unavailableReason ?? $0.detail } }
    public var verticalNote: String? {
        guard selected?.vertical == true else { return nil }
        let height = sourceHeight ?? 720
        return "This service takes a vertical picture: the stream is a 9:16 center crop of the camera picture, "
            + "about \(height * 9 / 16) pixels wide from a \(height)p feed before scaling."
    }
    public var eligibilityNote: String? { eligibility.reason }
    /// The monitor shows the Go live control once a key is saved and the switch is on, and always
    /// while a stream runs.
    public var showsMonitorControl: Bool { phase.isRunning || (showOnMonitor && key == .saved) }
}

/// Every live stream string that is not built from a value above.
public enum LiveStreamCopy {
    public static let cardTitle = "Live stream"
    public static let serviceTitle = "Service"
    public static let serverTitle = "Server"
    public static let keyTitle = "Stream key"
    public static let keyPlaceholder = "Paste stream key"
    public static let qualityTitle = "Quality"
    public static let qualityCameraFeed = "Camera feed"
    public static let qualityUpscaled = "1080p upscaled"
    public static let qualityUpscaledDetail = "The camera feed scaled up to 1080p, with your LUT."
    public static let qualityCamera = "1080p from camera"
    public static let qualityCameraDetail = "Sharper picture, encoded by the camera, standard color, no LUT."
    public static let qualityCameraNeedsNetwork = "Save a shared network in the camera's Wi-Fi setup to use this."
    public static let cameraRetry = "Retry"
    public static func startOnNetwork(_ name: String) -> String { "Go live over \(name)" }
    public static let showOnMonitorTitle = "Go live button on the monitor"
    public static let lockedWhileLive = "Settings are locked while a stream runs."
    public static let save = "Save"
    public static let remove = "Remove"
    public static let paste = "Paste"
    public static let removeTitle = "Remove the stream key?"
    public static func removeMessage(service: String) -> String {
        "The key for \(service) is deleted from this phone. You can paste it again later."
    }
    public static let plainWarning =
        "Not encrypted. rtmp:// sends the picture and the stream key in the clear, so anyone on the network "
        + "path can read the key. Use rtmps:// when the service offers it."

    public static func startTitle(service: String) -> String { "Go live on \(service)?" }
    public static func startMessage(quality: LiveStreamQuality?, encrypted: Bool) -> String {
        let lead = quality.map { "\($0.line). " } ?? ""
        let body = quality?.kind == .camera
            ? "The camera's own picture goes out in standard color, without the monitor LUT, with the camera's sound. "
            : "The camera picture goes out with the monitor LUT; assists and controls do not. "
        let message = lead + body + "Camera recording is separate."
        return encrypted ? message : message + "\n\nNot encrypted: the stream and its key travel in the clear."
    }
    public static let startConfirm = "Go live"
    public static let cancel = "Cancel"
    public static let stopTitle = "End the stream?"
    public static let stopMessage = "Viewers see the stream end. Camera recording is not affected."
    public static let stopConfirm = "End stream"
    public static let stopCancel = "Keep streaming"
    /// The app-level pill's one action.
    public static let pillStop = "Stop"
    public static let restart = "Restart stream"
    public static let dismiss = "Dismiss"

    /// `m:ss` under an hour, `h:mm:ss` from an hour.
    public static func elapsed(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let (h, m, sec) = (s / 3600, s / 60 % 60, s % 60)
        return h > 0
            ? "\(h):\(twoDigits(m)):\(twoDigits(sec))"
            : "\(m):\(twoDigits(sec))"
    }

    public static func spokenElapsed(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let parts = [(s / 3600, "hour"), (s / 60 % 60, "minute"), (s % 60, "second")]
        let spoken = parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return spoken.isEmpty ? "0 seconds" : spoken.joined(separator: " ")
    }

    /// One decimal in Mbps from 1 Mbps (a whole number without the decimal), whole kbps below.
    public static func bitrate(_ bps: Int) -> String {
        bps >= 1_000_000 ? "\(number(Double(bps) / 1_000_000, decimals: 1)) Mbps" : "\(max(0, bps) / 1000) kbps"
    }

    public static func spokenBitrate(_ bps: Int) -> String {
        bps >= 1_000_000
            ? "\(number(Double(bps) / 1_000_000, decimals: 1)) megabits per second"
            : "\(max(0, bps) / 1000) kilobits per second"
    }

    /// A number with at most `decimals` places and no trailing zeros, always with a dot.
    static func number(_ value: Double, decimals: Int) -> String {
        var scale = 1.0
        for _ in 0..<decimals { scale *= 10 }
        let scaled = Int((value * scale).rounded())
        let whole = scaled / Int(scale)
        var fraction = String(scaled % Int(scale))
        guard decimals > 0, scaled % Int(scale) != 0 else { return String(whole) }
        while fraction.count < decimals { fraction = "0" + fraction }
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return "\(whole).\(fraction)"
    }

    private static func twoDigits(_ value: Int) -> String { value < 10 ? "0\(value)" : String(value) }
}
