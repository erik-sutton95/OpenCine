import Foundation
import OpenCineCore

public enum RecordDirection: Hashable, Codable, Sendable {
    case start
    case stop

    /// Always an explicit intent: a blind toggle is never sent (plan 5.4).
    public var intent: CameraCommandIntent { self == .start ? .startRecording : .stopRecording }
}

public enum TargetPolicy: Hashable, Codable, Sendable {
    /// Every requested entry must be eligible; otherwise nothing is commanded.
    case strict
    /// Command the eligible cameras and show the exclusions.
    case eligibleSubset
}

public enum ExclusionReason: Hashable, Sendable {
    case notMember
    /// Picture-only entry (capture device, relay picture): nothing to command.
    case noCameraSession
    /// No requested entry of this camera holds owner or lease authority.
    case noCommandAuthority
    /// The camera session has not reported a snapshot.
    case notReported
    /// The app is still running a step for this entry.
    case busy
    /// The camera itself reports it is starting or stopping.
    case cameraTransitioning
    /// Core's shared admission rule (`CameraSnapshot.rejection(of:at:)`), or
    /// `.recordingStateUnknown` when the camera has not reported whether it is recording.
    case rejected(CommandRejection)
}

public struct Exclusion: Hashable, Sendable {
    public var entry: MonitorEntryID
    public var reason: ExclusionReason

    public init(entry: MonitorEntryID, reason: ExclusionReason) {
        self.entry = entry
        self.reason = reason
    }
}

/// What one target's admission rested on. Routine telemetry (battery, storage, setting values,
/// snapshot revisions and timestamps) is deliberately absent, so it never invalidates a plan.
/// A replacement session, a new control epoch, changed capabilities (availability included),
/// changed authority, a mode change or a changed reported recording state do.
public struct AdmissionFingerprint: Hashable, Sendable {
    public var session: CameraSessionID
    public var epoch: ControlEpoch
    public var capabilityRevision: CapabilityRevision
    public var authority: ControlAuthority
    public var mode: CaptureMode?
    public var recording: RecordingState?

    public init(_ snapshot: CameraSnapshot) {
        session = snapshot.session
        epoch = snapshot.epoch
        capabilityRevision = snapshot.capabilities.revision
        authority = snapshot.authority
        mode = snapshot.mode.value
        recording = snapshot.recording.value
    }
}

/// One camera control session and every requested entry showing it. They share one command and
/// its result.
public struct RecordTarget: Hashable, Sendable {
    public var session: CameraSessionID
    public var entries: [MonitorEntryID]
    public var fingerprint: AdmissionFingerprint
}

/// A group start or stop, resolved before anything is sent (plan 8.2). `make` is a pure function
/// of the operation-relevant state, so the plan is stable under routine telemetry and
/// revalidation is "rebuild and compare".
public struct RecordPlan: Hashable, Sendable {
    public let direction: RecordDirection
    public let policy: TargetPolicy
    public let requested: [MonitorEntryID]
    /// Cameras that will be commanded, one per control session, in slot order.
    public let targets: [RecordTarget]
    /// Cameras already reporting the requested state: counted, never commanded.
    public let satisfied: [RecordTarget]
    public let exclusions: [Exclusion]

    /// Strict policy with any exclusion: nothing is commanded and the exclusions explain why.
    public var isRefused: Bool { policy == .strict && !exclusions.isEmpty }
    public var isExecutable: Bool { !isRefused && !targets.isEmpty }

    public static func make(
        _ direction: RecordDirection, policy: TargetPolicy, entries requested: [MonitorEntryID],
        in group: MulticamGroup, at state: MulticamSnapshot
    ) -> RecordPlan {
        var exclusions: [Exclusion] = []
        var order: [CameraSessionID] = []
        var bySession: [CameraSessionID: [MonitorEntryDescriptor]] = [:]
        var seen: Set<MonitorEntryID> = []
        for id in requested where seen.insert(id).inserted {
            guard let entry = group[id] else {
                exclusions.append(Exclusion(entry: id, reason: .notMember))
                continue
            }
            guard let session = entry.cameraSession else {
                exclusions.append(Exclusion(entry: id, reason: .noCameraSession))
                continue
            }
            if bySession[session] == nil { order.append(session) }
            bySession[session, default: []].append(entry)
        }

        var targets: [RecordTarget] = []
        var satisfied: [RecordTarget] = []
        for session in order {
            let entries = bySession[session]!
            let ids = entries.map(\.id)
            func exclude(_ reason: ExclusionReason) {
                exclusions += ids.map { Exclusion(entry: $0, reason: reason) }
            }
            guard entries.contains(where: { $0.controlAuthority.commands }) else {
                exclude(.noCommandAuthority)
                continue
            }
            guard let snapshot = state.cameras[session] else {
                exclude(.notReported)
                continue
            }
            if ids.contains(where: state.busy.contains) {
                exclude(.busy)
                continue
            }
            let probe = CameraCommand(
                direction.intent, preconditions: CommandPreconditions(snapshot))
            if let rejection = snapshot.rejection(of: probe, at: state.now) {
                exclude(.rejected(rejection))
                continue
            }
            // A camera that has not reported its recording state cannot be sorted into target or
            // already-satisfied, and a later report could not be told from the approved state.
            guard snapshot.recording.isKnown else {
                exclude(.rejected(.recordingStateUnknown))
                continue
            }
            let target = RecordTarget(
                session: session, entries: ids, fingerprint: AdmissionFingerprint(snapshot))
            switch (direction, snapshot.recording.value) {
            case (_, .transitioning?): exclude(.cameraTransitioning)
            case (.start, .recording?), (.stop, .idle?): satisfied.append(target)
            default: targets.append(target)
            }
        }
        // Requested order for display, whichever pass excluded the entry.
        let position = Dictionary(requested.enumerated().map { ($1, $0) }) { first, _ in first }
        return RecordPlan(
            direction: direction, policy: policy, requested: requested, targets: targets,
            satisfied: satisfied,
            exclusions: exclusions.sorted { position[$0.entry]! < position[$1.entry]! })
    }

    /// Whether the plan the operator approved still describes the cameras now: same members,
    /// sessions, epochs, capabilities, authority, modes, reported recording and exclusions.
    public func isCurrent(in group: MulticamGroup, at state: MulticamSnapshot) -> Bool {
        Self.make(direction, policy: policy, entries: requested, in: group, at: state) == self
    }
}

public enum RecordSubmissionError: Error, Hashable, Sendable {
    /// Strict policy with exclusions, or no camera to command.
    case notExecutable
    /// The state changed since the plan was made (for example a replacement session). Nothing
    /// was sent; make a new plan and show it again.
    case stale
}

/// One command's progress as a group result reports it.
public enum TargetOutcome: Hashable, Sendable {
    /// Admitted or sent, no answer yet.
    case pending
    /// The protocol accepted it; the camera has not reported the new state yet.
    case accepted
    case confirmed
    case rejected(CommandRejection)
    case failed(CommandFailure)
    case timedOut
    /// The camera may have acted but the link was lost.
    case outcomeUnknown
    /// Replaced before its outcome was known: a newer operation, or the entry now shows a
    /// replacement session that this result must not touch.
    case superseded

    public init(_ stage: CommandStage) {
        switch stage {
        case .created, .admitted, .sent: self = .pending
        case .accepted, .awaitingObservation: self = .accepted
        case .confirmed: self = .confirmed
        case .rejected(let rejection): self = .rejected(rejection)
        case .failed(.superseded): self = .superseded
        case .failed(let failure): self = .failed(failure)
        case .timedOut: self = .timedOut
        case .outcomeUnknown: self = .outcomeUnknown
        }
    }
}

/// Per-target outcomes of one submitted plan. Partial success is not a transaction: nothing here
/// (or anywhere in the engine) stops a camera because another failed. Compensation is a separate
/// explicit operator intent.
public struct RecordResult: Hashable, Sendable {
    public let plan: RecordPlan
    public let outcomes: [CameraSessionID: TargetOutcome]

    public var confirmed: Int { outcomes.values.filter { $0 == .confirmed }.count }

    /// The outcome for one entry, mapped back through its target. An entry that now shows a
    /// different session gets `.superseded`, so a late result never lands on a replacement.
    public func outcome(for entry: MonitorEntryID, in group: MulticamGroup) -> TargetOutcome? {
        guard let target = plan.targets.first(where: { $0.entries.contains(entry) }) else {
            return nil
        }
        guard group[entry]?.cameraSession == target.session else { return .superseded }
        return outcomes[target.session]
    }
}

/// The commands a plan sent, by target session.
public struct RecordSubmission: Hashable, Sendable {
    public let plan: RecordPlan
    public let operations: [CameraSessionID: OperationID]
    /// Each receipt as `submit` returned it.
    public let receipts: [CameraSessionID: CommandReceipt]

    /// Outcomes now, without waiting.
    public func current(sessions: [CameraSessionID: any CameraSession]) async -> RecordResult {
        await collect(sessions) { session, operation in await session.receipt(of: operation) }
    }

    /// Waits until every target finishes. The integration enforces timeouts and the command
    /// deadline; the engine runs no timer of its own.
    public func finished(sessions: [CameraSessionID: any CameraSession]) async -> RecordResult {
        await collect(sessions) { session, operation in await session.outcome(of: operation) }
    }

    private func collect(
        _ sessions: [CameraSessionID: any CameraSession],
        _ read: @escaping @Sendable (any CameraSession, OperationID) async -> CommandReceipt?
    ) async -> RecordResult {
        var outcomes = receipts.mapValues { TargetOutcome($0.stage) }
        await withTaskGroup(of: (CameraSessionID, CommandReceipt?).self) { group in
            for (id, operation) in operations {
                guard let session = sessions[id] else { continue }
                group.addTask { (id, await read(session, operation)) }
            }
            for await (id, receipt) in group {
                if let receipt { outcomes[id] = TargetOutcome(receipt.stage) }
            }
        }
        return RecordResult(plan: plan, outcomes: outcomes)
    }
}

extension RecordPlan {
    /// Revalidates against fresh state, then submits each target's explicit start or stop,
    /// at most `maxConcurrent` at a time. Sends nothing else.
    ///
    /// - Parameter deadline: how long a command stays valid, as `CommandPreconditions.deadline`.
    public func submit(
        in group: MulticamGroup, at state: MulticamSnapshot,
        sessions: [CameraSessionID: any CameraSession], deadline: Duration? = nil,
        maxConcurrent: Int = 4
    ) async throws(RecordSubmissionError) -> RecordSubmission {
        guard isExecutable else { throw .notExecutable }
        guard isCurrent(in: group, at: state) else { throw .stale }
        let commands = targets.map { target in
            CameraCommand(
                direction.intent,
                preconditions: CommandPreconditions(
                    state.cameras[target.session]!, deadline: deadline.map { state.now + $0 }))
        }
        var receipts: [CameraSessionID: CommandReceipt] = [:]
        var work = zip(targets.map(\.session), commands).makeIterator()
        await withTaskGroup(of: (CameraSessionID, CommandReceipt).self) { group in
            func next() -> Bool {
                while let (id, command) = work.next() {
                    guard let session = sessions[id] else {
                        // No runtime for this target: report it honestly, never skip silently.
                        receipts[id] = CommandReceipt(
                            operation: command.operation, session: id, intent: command.intent,
                            stage: .failed(.notSent))
                        continue
                    }
                    group.addTask { (id, await session.submit(command)) }
                    return true
                }
                return false
            }
            var running = 0
            while running < max(maxConcurrent, 1), next() { running += 1 }
            for await (id, receipt) in group {
                receipts[id] = receipt
                _ = next()
            }
        }
        return RecordSubmission(
            plan: self,
            operations: Dictionary(
                uniqueKeysWithValues: zip(targets.map(\.session), commands.map(\.operation))),
            receipts: receipts)
    }
}

extension ControlAuthority {
    /// Owner or lease: this entry may command its session.
    var commands: Bool {
        switch self {
        case .owner, .lease: true
        case .readOnly, .unavailable: false
        }
    }
}
