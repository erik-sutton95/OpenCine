import Foundation
import OpenCineCore

// NIKON-01: what running several Z bodies at once taught the engine-port branch, re-homed on the
// shared engine. OpenCineMulticam owns membership, group plans and leases; this file owns the
// Nikon facts they need: which saved paths may join, what makes two paths the same body, and the
// command side of a member's own control pump. The member limit is the app's qualification policy
// (an OpenCineMulticam `ResourceBudget`), not a Nikon or engine constant.

/// Why a saved Nikon path cannot join a multicam group.
public enum NikonMulticamRefusal: Hashable, Sendable {
    /// The same body (by serial) is already a member, whatever host or path it is saved under. A
    /// body holds one PTP session, so a second path to it would fight the first.
    case alreadyMember
    /// The phone would join this camera's own access point and leave every other member's network.
    case cameraAccessPoint
    /// HDMI capture is a picture source with no control link: nothing to record or poll.
    case hdmiCapture
    /// Photography mode: the group operation is movie record.
    case photographyMode
    /// Not on the network the phone is on now, or no declared path.
    case notReachable
}

public enum NikonMulticamPolicy {
    /// Qualification for opening a saved member path. A path qualified before connect still
    /// rechecks body identity and camera-reported mode after connect; it asserts neither a
    /// serial nor movie mode that the camera has not reported. An unknown photography observation
    /// permits opening an eligible saved path only, never a movie record operation.
    public static func qualification(
        path: CameraPath?, reachable: Bool, isPhotography: Bool?, device: CameraDeviceID?,
        members: some Collection<CameraDeviceID>
    ) -> MulticamQualification {
        let reason: NikonMulticamRefusal?
        if let device, members.contains(device) {
            reason = .alreadyMember
        } else if let isPhotography, isPhotography {
            reason = .photographyMode
        } else {
            reason = pathRefusal(path: path, reachable: reachable)
        }
        guard let reason else { return .qualified }
        let common: MulticamQualificationRefusal =
            switch reason {
            case .alreadyMember: .alreadyMember
            case .cameraAccessPoint: .unsupportedConfiguration
            case .hdmiCapture, .photographyMode: .operationUnavailable
            case .notReachable: .notReachable
            }
        return .refused(common)
    }

    /// The member identity of a body: its serial, the same `CameraDeviceID` its
    /// `NikonCameraSession` reports. `nil` until a connect has stamped the serial; such a path is
    /// checked again once its session reports one.
    public static func device(serialNumber: String?) -> CameraDeviceID? {
        NikonCameraSession.durableDevice(serialNumber: serialNumber)
    }

    /// Why this path cannot join next to `members`, or `nil` when it may. USB-C, router and
    /// hotspot paths may mix in one group (the engine-port's qualified routes).
    public static func refusal(
        path: CameraPath?, reachable: Bool, isPhotography: Bool, device: CameraDeviceID?,
        members: some Collection<CameraDeviceID>
    ) -> NikonMulticamRefusal? {
        if let device, members.contains(device) { return .alreadyMember }
        if isPhotography { return .photographyMode }
        return pathRefusal(path: path, reachable: reachable)
    }

    /// Route eligibility is independent of a camera mode observation.
    private static func pathRefusal(path: CameraPath?, reachable: Bool) -> NikonMulticamRefusal? {
        switch path?.kind {
        case .cameraAccessPoint?: return .cameraAccessPoint
        case .hdmiCapture?: return .hdmiCapture
        case nil: return .notReachable
        case .usbC?, .infrastructure?, .phoneHotspot?: return reachable ? nil : .notReachable
        }
    }
}

/// The link a member's pump owns: one PTP session, one transaction at a time. OpenZCine's
/// `NativeCameraSession` has exactly these calls.
public protocol NikonControlTransport: AnyObject, Sendable {
    /// Unknown for legacy/scripted links which do not accept supplied operation authority.
    var commandOwner: NikonCommandOwner? { get }
    func writeCameraProperty(_ write: PTPCameraPropertyWrite) async throws
    func writeCameraProperty(_ write: PTPCameraPropertyWrite, admission: NikonCommandAdmission)
        async throws
    func readCameraProperty(_ property: PTPPropertyCode) async throws -> Data
    func startRecording() async throws
    func startRecording(admission: NikonCommandAdmission) async throws
    func stopRecording() async throws
    func stopRecording(admission: NikonCommandAdmission) async throws
}

extension NikonControlTransport {
    public var commandOwner: NikonCommandOwner? { nil }
    public func writeCameraProperty(
        _ write: PTPCameraPropertyWrite, admission: NikonCommandAdmission
    ) async throws {
        try admission.require(owner: commandOwner)
        try await writeCameraProperty(write)
    }
    public func startRecording(admission: NikonCommandAdmission) async throws {
        try admission.require(owner: commandOwner)
        try await startRecording()
    }
    public func stopRecording(admission: NikonCommandAdmission) async throws {
        try admission.require(owner: commandOwner)
        try await stopRecording()
    }
}

/// The command side of one Nikon control pump that the app's single-camera model does not own (a
/// multicam member). Settings writes and record requests wait here until the pump reaches its safe
/// point between live-view frames, then go out one at a time on that member's link only. Every
/// write is read back and reported to that member's own `NikonCameraSession`; nothing is dropped
/// or swallowed without a receipt saying so.
@MainActor
public final class NikonMemberControl: NikonControlDriver {
    public enum WriteOutcome: Hashable, Sendable {
        /// The camera reports the requested value.
        case applied
        /// The camera took the write but reports something else (clamped, locked, refused in part).
        case notApplied
        /// Sent, but the read after it failed: the value may have landed.
        case unknown
        /// The write failed; `refused` when the body answered with a PTP refusal.
        case failed(refused: Bool)
    }

    public struct WriteResult: Equatable, Sendable {
        public let write: PTPCameraPropertyWrite
        public let outcome: WriteOutcome
    }

    public var nikonControlFacts: NikonControlFacts
    /// This member's common session; the app puts its id in the group entry.
    public private(set) var session: NikonCameraSession!
    /// True while the member's link is lent to a full Live View: that view's own pump owns the
    /// link, so this one sends nothing (two pumps would interleave PTP transactions).
    public private(set) var isLent = false
    public var hasQueuedCommands: Bool { !writes.isEmpty || record != nil }

    private var writes: [(write: PTPCameraPropertyWrite, operation: OperationID?, admission: NikonCommandAdmission?)] = []
    private var record: (start: Bool, operation: OperationID, admission: NikonCommandAdmission?)?
    private let commandOwner: NikonCommandOwner?
    private let isCameraRefusal: @Sendable (any Error) -> Bool

    public init(
        serialNumber: String, facts: NikonControlFacts = NikonControlFacts(),
        recordObservationTimeout: Duration = .seconds(5),
        now: @escaping @Sendable () -> MonotonicInstant = MonotonicInstant.now,
        commandOwner: NikonCommandOwner? = nil,
        isCameraRefusal: @escaping @Sendable (any Error) -> Bool
    ) {
        nikonControlFacts = facts
        self.commandOwner = commandOwner
        self.isCameraRefusal = isCameraRefusal
        session = NikonCameraSession(
            driver: self, serialNumber: serialNumber,
            recordObservationTimeout: recordObservationTimeout, now: now)
    }

    /// Applies what the pump just read from the camera and republishes the session snapshot.
    public func update(_ change: (inout NikonControlFacts) -> Void) {
        change(&nikonControlFacts)
        session.refresh()
    }

    /// Queues a raw property write (a setting outside the common slice). Last value per property
    /// wins; a replaced write's operation is reported superseded.
    public func enqueue(_ write: PTPCameraPropertyWrite, operation: OperationID? = nil) {
        enqueue(write, operation: operation, suppliedAdmission: nil)
    }

    private func enqueue(
        _ write: PTPCameraPropertyWrite, operation: OperationID?,
        suppliedAdmission: NikonCommandAdmission?
    ) {
        guard !isLent else {
            if let operation { session.operationDropped(operation) }
            return
        }
        for queued in writes where queued.write.property == write.property {
            if let earlier = queued.operation {
                session.operationDropped(earlier, superseded: true)
            }
        }
        writes.removeAll { $0.write.property == write.property }
        writes.append((write, operation, suppliedAdmission))
    }

    /// Lends the link to a full Live View: queued commands are reported not sent, and until
    /// `reclaim` new ones are refused and the pump sends nothing. The session stays open (no
    /// CloseSession), so the member keeps its session ID and group plans made before the loan stay
    /// current after it.
    public func lend() {
        reset()
        isLent = true
    }

    public func reclaim() { isLent = false }

    /// Drops everything queued, reporting each operation as not sent.
    public func reset() {
        for queued in writes {
            if let operation = queued.operation { session.operationDropped(operation) }
        }
        writes.removeAll()
        if let request = record { session.operationDropped(request.operation) }
        record = nil
    }

    /// The pump's safe point: sends the queued writes, then the record request, each reported to
    /// this member's session. Returns every write's outcome so the caller can show failures.
    @discardableResult
    public func service(_ transport: some NikonControlTransport) async -> [WriteResult] {
        guard !isLent else { return [] }
        var results: [WriteResult] = []
        while !isLent, !writes.isEmpty {
            let (write, operation, admission) = writes.removeFirst()
            if let admission {
                session.refresh()
                guard admits(admission), admission.admits(transport.commandOwner) else {
                    if let operation {
                        session.commandAdmissionExpired(operation)
                        writes.removeAll { $0.operation == operation }
                    }
                    continue
                }
            }
            if let operation { session.operationSent(operation) }
            do {
                if let admission {
                    try await transport.writeCameraProperty(write, admission: admission)
                } else {
                    try await transport.writeCameraProperty(write)
                }
            } catch {
                if admission != nil, case NativeCameraSessionError.commandAuthorityExpired = error {
                    if let operation {
                        session.commandAdmissionExpired(operation)
                        writes.removeAll { $0.operation == operation }
                    }
                    continue
                }
                let refused = isCameraRefusal(error)
                if let operation { session.commandFailed(operation, cameraRefused: refused) }
                // The camera decides what is shown: re-read so no optimistic value survives.
                await reread(write.property, on: transport)
                results.append(WriteResult(write: write, outcome: .failed(refused: refused)))
                continue
            }
            let readback = try? await transport.readCameraProperty(write.property)
            if let readback {
                nikonControlFacts.reported = nikonControlFacts.reported.applying(
                    property: write.property, data: readback)
            }
            if let operation { session.writeLanded(operation, write: write, readback: readback) }
            if admission != nil { session.refresh() }
            let outcome: WriteOutcome =
                readback.map {
                    NikonCameraSession.readbackMatches(write, $0) ? .applied : .notApplied
                }
                ?? .unknown
            results.append(WriteResult(write: write, outcome: outcome))
        }
        if !isLent, let request = record {
            record = nil
            if let admission = request.admission {
                session.refresh()
                guard admits(admission), admission.admits(transport.commandOwner) else {
                    session.commandAdmissionExpired(request.operation)
                    session.refresh()
                    return results
                }
            }
            session.operationSent(request.operation)
            do {
                if let admission = request.admission {
                    if request.start {
                        try await transport.startRecording(admission: admission)
                    } else {
                        try await transport.stopRecording(admission: admission)
                    }
                } else if request.start {
                    try await transport.startRecording()
                } else {
                    try await transport.stopRecording()
                }
                session.recordAccepted(request.operation)
            } catch {
                if request.admission != nil, case NativeCameraSessionError.commandAuthorityExpired = error {
                    session.commandAdmissionExpired(request.operation)
                } else {
                    session.commandFailed(request.operation, cameraRefused: isCameraRefusal(error))
                }
            }
        }
        session.refresh()
        return results
    }

    // MARK: NikonControlDriver

    public func queueSettingWrites(
        _ label: String, for setting: NikonControlSetting, operation: OperationID?
    ) -> Int {
        guard !isLent else { return 0 }
        let encoded = PTPCameraPropertyWrite.requests(
            control: setting.cameraControl, label: label, snapshot: nikonControlFacts.reported)
        for write in encoded { enqueue(write, operation: operation) }
        return encoded.count
    }

    /// Supplied authority is accepted only for this member's established native owner.
    public func admits(_ admission: NikonCommandAdmission) -> Bool {
        !isLent && admission.admits(commandOwner)
    }

    public func queueSettingWrites(
        _ label: String, for setting: NikonControlSetting, operation: OperationID?,
        admission: NikonCommandAdmission
    ) -> Int {
        guard admits(admission) else { return 0 }
        let encoded = PTPCameraPropertyWrite.requests(
            control: setting.cameraControl, label: label, snapshot: nikonControlFacts.reported)
        for write in encoded { enqueue(write, operation: operation, suppliedAdmission: admission) }
        return encoded.count
    }

    /// A newer press replaces a queued one, which is reported superseded.
    public func queueRecord(start: Bool, operation: OperationID) {
        guard !isLent else { return session.operationDropped(operation) }
        if let earlier = record { session.operationDropped(earlier.operation, superseded: true) }
        record = (start, operation, nil)
    }

    public func queueRecord(start: Bool, operation: OperationID, admission: NikonCommandAdmission) {
        guard admits(admission) else { return session.commandAdmissionExpired(operation) }
        if let earlier = record { session.operationDropped(earlier.operation, superseded: true) }
        record = (start, operation, admission)
    }

    private func reread(_ property: PTPPropertyCode, on transport: some NikonControlTransport) async
    {
        // ponytail: best effort; the failure itself is already reported above.
        guard let actual = try? await transport.readCameraProperty(property) else { return }
        nikonControlFacts.reported = nikonControlFacts.reported.applying(
            property: property, data: actual)
    }
}
