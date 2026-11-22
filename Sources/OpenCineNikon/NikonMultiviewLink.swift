import Foundation
import OpenCineCore

// Shared Multiview (Plan 6): one Nikon member's link as the shared coordinator drives it, over the
// prep operations (`NikonMemberOpener`, `NikonMemberRepair`, `NikonRecordingTone`) and the member
// control (`NikonMemberControl`). Kotlin twin: `NikonMultiviewLink.kt`, same names.

/// What a Nikon Multiview member's link runs on: one PTP session to one body, one transaction at a
/// time. `NativeCameraSession` provides it on iOS; tests script it. Kotlin twin: the nikon
/// `CameraSession` with its frame flow.
public protocol NikonMultiviewTransport: NikonControlTransport {
    /// The serial GetDeviceInfo reported after OpenSession; empty when the body gave none.
    var serialNumber: String { get }
    /// Sets the preview stream's size and compression (never the card recording format).
    func configureMemberLiveView() async
    func startLiveView() async throws
    func stopLiveView() async
    /// One bounded, parsed frame.
    func liveViewFrame(deadline: Duration?) async throws -> PTPLiveViewFrame
    func readStorageInfo() async throws -> PTPStorageInfo?
    /// A graceful CloseSession, then the sockets. Never a record command.
    func shutdown() async
}

#if canImport(Darwin) && canImport(os)
    extension NativeCameraSession: NikonMultiviewTransport {
        public func configureMemberLiveView() async { await configureLiveView() }
    }
#endif

/// Why a Nikon member link did not open, with its operator copy (the shared coordinator shows it
/// on the tile: `MultiviewLinkRefusal`). Kotlin twin: `NikonMultiviewLinkError`.
public enum NikonMultiviewLinkError: LocalizedError, Equatable, Sendable, MultiviewLinkRefusal {
    /// `NikonMemberOpener` refused the body (`heldBy` for `.heldByAnotherDevice`).
    case refused(NikonMemberOpenRefusal, heldBy: String?)
    /// `startPreview` found no open link.
    case notOpen
    /// The body does not know this phone: it is paired in the app's camera list first.
    case notPaired

    /// The refusal a failed connect means for the operator, nil for a dial that simply failed
    /// (the coordinator then says it could not find the camera): a body that does not know this
    /// phone, or one another device took between the holder check and the Init.
    public static func connectFailure(_ error: any Error) -> NikonMultiviewLinkError? {
        switch error {
        case let refusal as NikonMultiviewLinkError: refusal
        case NativeCameraSessionError.savedProfileRequired, NativeCameraSessionError.pairingRejected,
            NativeCameraSessionError.pairingChallengeUnavailable,
            NativeCameraSessionError.initFailed(.rejectedInitiator):
            .notPaired
        case NativeCameraSessionError.initFailed(.busy): .refused(.heldByAnotherDevice, heldBy: nil)
        default: nil
        }
    }

    public var operatorMessage: String { errorDescription ?? "" }

    public var errorDescription: String? {
        switch self {
        case .refused(.hostInUse, _):
            "This camera is still connecting. Wait a moment, then tap Reconnect."
        case .refused(.heldByAnotherDevice, let holder): NikonMultiviewCopy.heldBy(holder)
        case .refused(.alreadyMember, _): "This camera is already in Multiview."
        case .refused(.differentBody, _):
            "Another camera answered at this address. Remove this tile and add the camera again."
        case .refused(.noIdentity, _):
            "This camera did not report its serial number, so Multiview cannot tell it from others."
        case .notOpen: "Could not connect preview."
        case .notPaired:
            "This camera is not paired with this phone. Pair it in Your cameras, then tap Reconnect."
        }
    }
}

/// The member link's operator copy. Kotlin twin: `NikonMultiviewCopy`.
public enum NikonMultiviewCopy {
    /// The automatic repairs are spent (the same words as every app's Multiview).
    public static let couldNotRestore = "Could not restore preview. Tap Reconnect to try again."

    /// Another device holds the body: nothing here takes it back.
    public static func heldBy(_ holder: String?) -> String {
        guard let holder, !holder.isEmpty else {
            return "Another device is using this camera. Release it there, then tap Reconnect."
        }
        return "In use on \(holder). Release it there, then tap Reconnect."
    }
}

/// One Nikon Multiview member's link (Kotlin twin: `NikonMultiviewLink`). The coordinator owns the
/// tile; this link opens the picked body at its address with the identity check and the reconnect
/// settle (`NikonMemberOpener`, shared by every link of a stage), runs the member pump (a frame,
/// then the queued writes and record at the safe point between frames, the property, storage and
/// tone poll every `pollInterval` outside a take), and repairs within the coordinator's budget
/// (`NikonMemberRepair`: three missed frames restart live view in place once, then reopen the same
/// body; each attempt asks `beginAttempt`; spent or taken over waits for the operator). It never
/// returns `.rejoin`, so the coordinator never spends a second attempt per repair.
///
/// The common session is the open link's (`NikonMemberControl`): `NikonCameraSession` carries the
/// body's serial from its start, so an open or a reopen makes a new one and earlier plans and
/// editor leases go stale. Before the first open, and after a close, it is a closed session.
@MainActor
public final class NikonMultiviewLink<Transport: NikonMultiviewTransport>: MultiviewMemberLink {
    public typealias Camera = NikonMultiviewCamera

    /// Movie values the member poll reads outside a take, battery first (the tile's health). The
    /// codec and its tone are the tone poll's.
    public static var polledProperties: [PTPPropertyCode] {
        [
            .batteryLevel, .liveViewSelector, .isoControlSensitivity, .movieISOSensitivity,
            .movieISOAutoControl, .movieShutterMode, .movieShutterAngle, .movieShutterSpeed,
            .movieWhiteBalance, .movieWBColorTemp, .movieFocusMode, .movieRecordScreenSize,
            .exposureProgramMode,
        ]
    }

    private let opener: NikonMemberOpener<Transport>
    private let conversion: @Sendable (NikonMovieTone) -> String?
    private let whiteBalancePresets: [String]
    private let isCameraRefusal: @Sendable (any Error) -> Bool
    private let isLinkFailure: @Sendable (any Error) -> Bool
    private let clock: HostClock
    private let frameDeadline: Duration
    private let framePace: @MainActor () -> Duration
    private let pollInterval: Duration
    private let idle: NikonMemberControl
    private var ladder: NikonMemberRepair
    private var pump: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    /// Bumps on every open, reopen and close: late work of an older link changes nothing.
    private var generation = 0
    private var missedFrames = 0
    private var device: CameraDeviceID?
    private var holder: String?

    /// Where the link reports its status; the coordinator sets it.
    public var onStatus: (@MainActor (MultiviewLinkStatus) -> Void)?
    /// Each picture of the current link as it arrives; the app's tile decodes and grades it.
    public var onFrame: (@MainActor (PTPLiveViewFrame) -> Void)?
    /// The open link, nil while none is open or while it is lent to Live View.
    public private(set) var transport: Transport?
    /// The open link's member control: its session is the member's, its facts the tile's values.
    public private(set) var control: NikonMemberControl?
    /// Where the open link reached its body; empty before the first open.
    public private(set) var host = ""
    /// The link is lent to the app's Live View (`lend()`).
    public private(set) var lent = false
    public private(set) var recordReport: MultiviewRecordReport?
    public private(set) var pictureHealth = PictureHealth.starting
    /// The last frame's header timecode.
    public private(set) var timecode: Timecode?
    /// The card the body last reported (outside a take).
    public private(set) var storage: PTPStorageInfo?
    /// Above the ladder's 30 s attempt deadline, the settle and the spacing between reopens.
    public let repairDeadline: Duration = .seconds(45)

    /// - `opener`: the stage's one opener (every link of a stage shares it).
    /// - `conversion`: the app's look title for a recording tone, nil when none is needed.
    /// - `framePace`: the pause after each frame (the app sheds non-program cadence under load).
    /// - `isLinkFailure`: a frame fetch that failed this way lost the link (the transport closed its
    ///   socket at the frame deadline, or the body hung up): the ladder reopens at once instead of
    ///   restarting live view on a dead socket.
    public init(
        opener: NikonMemberOpener<Transport>,
        conversion: @escaping @Sendable (NikonMovieTone) -> String?,
        whiteBalancePresets: [String] = [],
        isCameraRefusal: @escaping @Sendable (any Error) -> Bool,
        isLinkFailure: @escaping @Sendable (any Error) -> Bool = {
            NativeCameraSessionError.isLinkFailure($0)
        },
        clock: HostClock = .live,
        frameDeadline: Duration = .seconds(10),
        framePace: (@MainActor () -> Duration)? = nil,
        pollInterval: Duration = .seconds(5),
        repair: NikonMemberRepair = NikonMemberRepair()
    ) {
        self.opener = opener
        self.conversion = conversion
        self.whiteBalancePresets = whiteBalancePresets
        self.isCameraRefusal = isCameraRefusal
        self.isLinkFailure = isLinkFailure
        self.clock = clock
        self.frameDeadline = frameDeadline
        self.framePace = framePace ?? { .milliseconds(41) }
        self.pollInterval = pollInterval
        ladder = repair
        idle = NikonMemberControl(serialNumber: "", isCameraRefusal: isCameraRefusal)
        idle.session.close(.requested)
    }

    // MARK: MultiviewMemberLink

    public var session: any CameraSession { (control ?? idle).session }
    public var snapshot: CameraSnapshot { (control ?? idle).session.refresh() }

    /// Values exactly as read back from the body.
    public var reported: PTPCameraPropertySnapshot {
        control?.nikonControlFacts.reported ?? PTPCameraPropertySnapshot()
    }

    /// The tone the body records in now; nil until read.
    public var recordingTone: NikonMovieTone? { control?.recordingTone.tone }

    public var autoLUT: MultiviewAutoLUT {
        let tone = recordingTone
        return MultiviewAutoLUT(colorMode: tone?.label, conversion: tone.flatMap(conversion))
    }

    /// Never asked: the policy does not discover by probe (an unasked Init drops a held session).
    public func probe(_ address: String, on network: StationNetwork) async -> Bool { false }

    public func open(
        _ camera: NikonMultiviewCamera, at address: String, expecting identity: [UInt8]?,
        on network: StationNetwork
    ) async throws -> [UInt8] {
        close()
        if let closing { await closing.value }
        generation &+= 1
        let mine = generation
        onStatus?(.opening)
        let expected = identity.map { String(decoding: $0, as: UTF8.self) }
        let result: NikonMemberOpenResult<Transport>
        do {
            result = try await opener.open(
                host: address, expectedSerial: expected, members: [], hostsInUse: [])
        } catch {
            throw NikonMultiviewLinkError.connectFailure(error) ?? error
        }
        guard case .opened(let opened, let device) = result else {
            holder = result.heldBy
            throw NikonMultiviewLinkError.refused(result.refusal ?? .hostInUse, heldBy: result.heldBy)
        }
        guard mine == generation, !Task.isCancelled else {
            await opener.close(opened, host: address)
            throw CancellationError()
        }
        attach(opened, host: address, device: device)
        ladder.reset()
        return Self.identity(opened)
    }

    public func startPreview(_ camera: NikonMultiviewCamera) async throws {
        guard let transport, control != nil else { throw NikonMultiviewLinkError.notOpen }
        let mine = generation
        onStatus?(.controlling)
        await transport.configureMemberLiveView()
        try await transport.startLiveView()
        guard mine == generation else { throw CancellationError() }
        onStatus?(.awaitingPicture)
        startPump(restartingLiveView: false)
    }

    /// The pump keeps the session busy; nothing to send here, so it returns at once.
    public func keepalive() async {}

    /// Ends the session (CloseSession, never a record command) after stopping live view, in the
    /// background; the next `open` waits for it, and the opener starts the host's settle.
    public func close() {
        generation &+= 1
        pump?.cancel()
        pump = nil
        lent = false
        missedFrames = 0
        recordReport = nil
        pictureHealth = .starting
        control?.session.close(.requested)
        control = nil
        guard let transport else { return }
        self.transport = nil
        let host = host
        let opener = opener
        let previous = closing
        closing = Task {
            await previous?.value
            await transport.stopLiveView()
            await opener.close(transport, host: host)
        }
    }

    /// Returns once every close this link started has reached the opener (CloseSession sent or
    /// given up): the app's own single-camera connect waits for it, then the settle, before it
    /// dials a body a member held.
    public func awaitClosed() async {
        await closing?.value
    }

    public func repair(_ context: MultiviewRepairContext) -> MultiviewRepairStep {
        guard device != nil, !lent else { return .healthy }
        context.observeHealth(pictureHealth == .live && missedFrames == 0)
        // Without the shared network the coordinator's path-loss rule decides, not the ladder.
        guard context.pathReady else { return .healthy }
        switch ladder.next(at: clock.now(), beginAttempt: context.beginAttempt) {
        case .none: return .healthy
        case .wait:
            onStatus?(.reconnecting)
            return .handled
        case .restartLiveView:
            onStatus?(.reconnecting)
            return .repair { [weak self] in
                await self?.restartLiveView()
                return .done
            }
        case .reopen:
            onStatus?(.reconnecting)
            return .repair { [weak self] in
                await self?.reopen()
                return .done
            }
        case .waitForOperator(.takenOver): return .waitForOperator(NikonMultiviewCopy.heldBy(holder))
        case .waitForOperator(.budgetSpent): return .waitForOperator(NikonMultiviewCopy.couldNotRestore)
        }
    }

    // MARK: Live View loan

    /// Lends the open link to the app's Live View: this pump stops, queued commands are reported
    /// not sent and new ones refused until `reclaim`; the session stays open. Nil when nothing is
    /// open or it is already lent.
    public func lend() -> Transport? {
        guard let transport, let control, !lent else { return nil }
        lent = true
        pump?.cancel()
        pump = nil
        control.lend()
        return transport
    }

    /// The Live View stood down without closing the session. `returned` is what it holds now: the
    /// lent link (this pump restarts live view on it), a replacement a recovery opened for the same
    /// body (a new control), or nil (the link is lost: the repair ladder takes over). A replacement
    /// of another body is closed and counts as lost.
    public func reclaim(_ returned: Transport?) {
        guard lent else { return }
        lent = false
        if let returned, returned === transport, let control {
            control.reclaim()
            startPump(restartingLiveView: true)
            return
        }
        generation &+= 1
        pump?.cancel()
        pump = nil
        control?.session.close(.linkLost)
        control = nil
        let lost = transport
        transport = nil
        let now = clock.now()
        // The Live View lost it: close it through the opener, so the reopen waits out the settle
        // after this close, not one the opener never saw.
        if returned == nil, let lost { drop(lost) }
        if let returned {
            let body = NikonMulticamPolicy.device(serialNumber: returned.serialNumber)
            if body == device, let device {
                attach(returned, host: host, device: device)
                startPump(restartingLiveView: true)
                return
            }
            let opener = opener
            let host = host
            Task { await opener.close(returned, host: host) }
        }
        pictureHealth = .stalled
        ladder.linkLost(at: now)
        onStatus?(.reconnecting)
    }

    // MARK: Pump

    private static func identity(_ transport: Transport) -> [UInt8] {
        Array(transport.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }

    private func attach(_ opened: Transport, host: String, device: CameraDeviceID) {
        transport = opened
        self.host = host
        self.device = device
        holder = nil
        missedFrames = 0
        recordReport = nil
        storage = nil
        timecode = nil
        pictureHealth = .starting
        control = NikonMemberControl(
            serialNumber: opened.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines),
            facts: NikonControlFacts(whiteBalancePresets: whiteBalancePresets),
            now: clock.now, commandOwner: opened.commandOwner, isCameraRefusal: isCameraRefusal)
    }

    private func startPump(restartingLiveView: Bool) {
        pump?.cancel()
        guard let transport, let control, !lent else { return }
        let mine = generation
        pump = Task { [weak self] in
            await self?.runPump(transport, control, mine, restartingLiveView: restartingLiveView)
        }
    }

    private func current(_ mine: Int) -> Bool { !Task.isCancelled && mine == generation && !lent }

    private func runPump(
        _ transport: Transport, _ control: NikonMemberControl, _ mine: Int, restartingLiveView: Bool
    ) async {
        if restartingLiveView {
            await transport.stopLiveView()
            await transport.configureMemberLiveView()
            do { try await transport.startLiveView() } catch {
                guard current(mine) else { return }
                stalled()
                return
            }
        }
        var nextPoll = clock.now()
        while current(mine) {
            await control.service(transport)
            guard current(mine) else { return }
            do {
                let frame = try await transport.liveViewFrame(deadline: frameDeadline)
                guard current(mine) else { return }
                arrived(frame, control)
                if clock.now() >= nextPoll {
                    await poll(transport, control, mine, recording: frame.isRecording == true)
                    nextPoll = clock.now() + pollInterval
                }
            } catch {
                guard current(mine) else { return }
                control.update { $0.liveViewReady = false }
                if isLinkFailure(error) {
                    lost()
                    return
                }
                missedFrames += 1
                ladder.frameMissed(at: clock.now())
                if missedFrames >= NikonMemberRepair.missedFramesForStall {
                    stalled()
                    return
                }
                try? await clock.sleep(.milliseconds(250))
                continue
            }
            let pace = framePace()
            if pace > .zero { try? await clock.sleep(pace) }
        }
    }

    /// The pump found the link dead: it is closed through the opener now (its settle runs beside
    /// the ladder's) and the coordinator's next repair tick reopens after the settle.
    private func lost() {
        if let transport {
            self.transport = nil
            drop(transport)
        }
        pictureHealth = .stalled
        ladder.linkLost(at: clock.now())
        onStatus?(.reconnecting)
    }

    /// The pump stopped on a stall: the coordinator's next repair tick runs the ladder.
    private func stalled() {
        pictureHealth = .stalled
        ladder.streamStalled(at: clock.now())
        onStatus?(.reconnecting)
    }

    private func arrived(_ frame: PTPLiveViewFrame, _ control: NikonMemberControl) {
        missedFrames = 0
        ladder.frameArrived()
        timecode = frame.timecode
        // A header without record state (Gen-1 bodies) is not a report of standby.
        if let recording = frame.isRecording {
            recordReport = MultiviewRecordReport(recording: recording, receivedAt: clock.date())
        }
        control.update {
            $0.liveViewReady = true
            if let recording = frame.isRecording { $0.recording = recording }
            $0.timecode = frame.timecode?.running
        }
        if pictureHealth != .live {
            pictureHealth = .live
            onStatus?(.live)
        }
        onFrame?(frame)
    }

    private func poll(
        _ transport: Transport, _ control: NikonMemberControl, _ mine: Int, recording: Bool
    ) async {
        // During a take only battery: the header carries record state and timecode, and the codec
        // and its tone cannot change.
        let codes = recording ? [PTPPropertyCode.batteryLevel] : Self.polledProperties
        var reads: [(PTPPropertyCode, Data)] = []
        for code in codes {
            // Telemetry only: a value that does not read stays unknown, never invented.
            if let data = try? await transport.readCameraProperty(code) { reads.append((code, data)) }
            guard current(mine) else { return }
        }
        let presets = whiteBalancePresets
        control.update { facts in
            facts.reported = reads.reduce(facts.reported) { $0.applying(property: $1.0, data: $1.1) }
            facts.whiteBalancePresets = PTPCameraPropertyDecoders.whiteBalanceOptions(
                advertised: presets, codec: facts.reported.fileType)
        }
        guard !recording else { return }
        await control.pollRecordingTone(on: transport)
        guard current(mine) else { return }
        if let card = try? await transport.readStorageInfo(), current(mine) {
            storage = card
            control.update { $0.storage = card }
        }
    }

    /// Closes a link that is no longer this member's through the opener, after any close before
    /// it; the next open or reopen waits for it.
    private func drop(_ link: Transport) {
        let opener = opener
        let host = host
        let previous = closing
        closing = Task {
            await previous?.value
            await opener.close(link, host: host)
        }
    }

    // MARK: Repair steps

    /// Ends live view and starts it again on the same session: no new Init.
    private func restartLiveView() async {
        guard let transport, control != nil else {
            ladder.attemptFailed(at: clock.now())
            return
        }
        let mine = generation
        pump?.cancel()
        pump = nil
        await transport.stopLiveView()
        do {
            try await transport.startLiveView()
            guard mine == generation, !Task.isCancelled else { return }
            // The restart counts only when a new picture arrives (`frameArrived` ends the episode);
            // without one the restarted pump stalls again and the ladder reopens.
            missedFrames = 0
            onStatus?(.awaitingPicture)
            startPump(restartingLiveView: false)
        } catch {
            guard mine == generation else { return }
            ladder.attemptFailed(at: clock.now())
        }
    }

    /// Closes the member's link and opens its host again, refusing any other body. A link handed
    /// back after the repair was given up (cancelled at the coordinator's deadline, or replaced) is
    /// closed here: nobody else owns it.
    private func reopen() async {
        guard let device else { return }
        generation &+= 1
        let mine = generation
        let host = host
        pump?.cancel()
        pump = nil
        control?.session.close(.linkLost)
        control = nil
        pictureHealth = .starting
        if let old = transport {
            transport = nil
            await opener.close(old, host: host)
        }
        // A link dropped earlier (lost, or lost in Live View) finishes closing first: the opener's
        // settle starts at its close.
        if let closing { await closing.value }
        do {
            let result = try await opener.reopen(device, host: host, members: [], hostsInUse: [])
            switch result {
            case .opened(let opened, _):
                guard mine == generation, !Task.isCancelled else {
                    await opener.close(opened, host: host)
                    return
                }
                attach(opened, host: host, device: device)
                await opened.configureMemberLiveView()
                try await opened.startLiveView()
                guard mine == generation, !Task.isCancelled else { return }
                ladder.attemptSucceeded()
                onStatus?(.awaitingPicture)
                startPump(restartingLiveView: false)
            case .refused(.heldByAnotherDevice, let heldBy):
                guard mine == generation else { return }
                holder = heldBy
                ladder.takenOver()
            case .refused:
                // `.hostInUse` here means an earlier dial of this host is still running: the
                // ladder spaces the next attempt.
                guard mine == generation else { return }
                ladder.attemptFailed(at: clock.now())
            }
        } catch {
            guard mine == generation else { return }
            ladder.attemptFailed(at: clock.now())
        }
    }
}
