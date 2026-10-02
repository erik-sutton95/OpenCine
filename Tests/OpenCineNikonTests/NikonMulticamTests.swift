import Foundation
import OpenCineCore
import OpenCineMulticam
import Testing

@testable import OpenCineNikon

/// NIKON-01: two to four Z bodies at once, each a real `NikonCameraSession` driven by its own
/// `NikonMemberControl`, through the shared OpenCineMulticam engine. A scripted transport stands in
/// for each body's PTP link; the pump step (`pump`) is what the app's member pump does per frame.
@MainActor
@Suite("Nikon multicam: 2-4 bodies on the shared engine")
struct NikonMulticamTests {

    struct Refusal: Error {}
    struct LinkLost: Error {}

    /// One scripted body. Answers like a Z body on its own PTP link.
    final class Body: NikonControlTransport, @unchecked Sendable {
        enum RecordAnswer { case starts, refuses, linkLost, acceptsButNeverReports }

        private let lock = NSLock()
        private var _sent: [String] = []
        private var _properties: [PTPPropertyCode: Data] = [:]
        private var _recording = false
        var recordAnswer = RecordAnswer.starts
        /// Readback the body reports instead of the written bytes (a clamp or a lock).
        var clamps: [PTPPropertyCode: Data] = [:]
        var refusesWrites: Set<PTPPropertyCode> = []
        var readFails = false

        var sent: [String] { lock.withLock { _sent } }
        var recording: Bool { lock.withLock { _recording } }

        func writeCameraProperty(_ write: PTPCameraPropertyWrite) async throws {
            lock.withLock { _sent.append("write \(write.property)") }
            if refusesWrites.contains(write.property) { throw Refusal() }
            lock.withLock { _properties[write.property] = clamps[write.property] ?? write.data }
        }

        func readCameraProperty(_ property: PTPPropertyCode) async throws -> Data {
            if readFails { throw LinkLost() }
            return lock.withLock { _properties[property] ?? Data() }
        }

        func startRecording() async throws { try record(true) }
        func stopRecording() async throws { try record(false) }

        private func record(_ start: Bool) throws {
            lock.withLock { _sent.append(start ? "start" : "stop") }
            switch recordAnswer {
            case .starts: lock.withLock { _recording = start }
            case .refuses: throw Refusal()
            case .linkLost: throw LinkLost()
            case .acceptsButNeverReports: break
            }
        }
    }

    @MainActor struct Member {
        let control: NikonMemberControl
        let body: Body
        let entry: MonitorEntryDescriptor
        var session: NikonCameraSession { control.session }
    }

    static let movie = NikonControlFacts(
        liveViewReady: true,
        reported: PTPCameraPropertySnapshot(
            iso: 800, isoAuto: false, exposureMode: "M", wbMode: "Auto", wbKelvin: 5560,
            fileType: "H.265 10-bit MOV", batteryPercent: 80, captureSelector: .video),
        recording: false, whiteBalancePresets: ["Auto", "Sunny", "Cloudy"])

    static func member(_ index: Int, facts: NikonControlFacts = movie) -> Member {
        let serial = "300012\(index)"
        let control = NikonMemberControl(
            serialNumber: serial, facts: facts, recordObservationTimeout: .milliseconds(50),
            isCameraRefusal: { $0 is Refusal })
        let entry = MonitorEntryDescriptor(
            name: "\(["A", "B", "C", "D"][index]) CAM",
            device: NikonMulticamPolicy.device(serialNumber: serial),
            cameraSession: control.session.id, telemetry: .cameraSession, controlAuthority: .owner)
        return Member(control: control, body: Body(), entry: entry)
    }

    static func group(_ members: [Member]) throws -> MulticamGroup {
        var group = MulticamGroup()
        for member in members { try group.add(member.entry) }
        return group
    }

    static func state(_ members: [Member], busy: Set<MonitorEntryID> = []) -> MulticamSnapshot {
        MulticamSnapshot(cameras: members.map { $0.session.refresh() }, busy: busy)
    }

    static func sessions(_ members: [Member]) -> [CameraSessionID: any CameraSession] {
        Dictionary(
            uniqueKeysWithValues: members.map { ($0.session.id, $0.session as any CameraSession) })
    }

    /// One pump step: the safe point, then the next frame's header says whether it records.
    @discardableResult
    static func pump(_ member: Member) async -> [NikonMemberControl.WriteResult] {
        let results = await member.control.service(member.body)
        member.control.update { $0.recording = member.body.recording }
        return results
    }

    // MARK: Group record

    @Test("Mixed group start: per-body results, no compensation", arguments: [2, 3, 4])
    func mixedGroupStart(count: Int) async throws {
        var notLive = Self.movie
        notLive.liveViewReady = false
        let members = (0..<count).map { index in
            Self.member(index, facts: index == 2 ? notLive : Self.movie)
        }
        members[1].body.recordAnswer = .refuses
        if count == 4 { members[3].body.recordAnswer = .acceptsButNeverReports }
        let group = try Self.group(members)
        let ids = group.entries.map(\.id)

        // Nikon keeps its mixed-result default: command the eligible bodies, show the rest.
        let plan = RecordPlan.make(
            .start, policy: .eligibleSubset, entries: ids, in: group, at: Self.state(members))
        // A body without its own live view keeps the record preflight and is shown, not sent.
        if count >= 3 {
            #expect(
                plan.exclusions == [
                    Exclusion(entry: ids[2], reason: .rejected(.unavailable(.notReady)))
                ])
            let strict = RecordPlan.make(
                .start, policy: .strict, entries: ids, in: group, at: Self.state(members))
            #expect(strict.isRefused)
        }
        #expect(plan.targets.count == count - (count >= 3 ? 1 : 0))

        let submission = try await plan.submit(
            in: group, at: Self.state(members), sessions: Self.sessions(members))
        for member in members { await Self.pump(member) }
        let result = await submission.finished(sessions: Self.sessions(members))

        #expect(result.outcome(for: ids[0], in: group) == .confirmed)
        #expect(result.outcome(for: ids[1], in: group) == .rejected(.cameraRefused))
        if count >= 3 {
            #expect(result.outcome(for: ids[2], in: group) == nil, "excluded, never sent")
            #expect(members[2].body.sent.isEmpty)
        }
        if count == 4 { #expect(result.outcome(for: ids[3], in: group) == .timedOut) }
        #expect(result.confirmed == 1)
        // Partial success is not a transaction: the body that started keeps rolling.
        #expect(members[0].body.sent == ["start"])
        #expect(members[0].session.refresh().recording.value == .recording)
        // A refusal and a timeout invent no state.
        #expect(members[1].session.refresh().recording.value == .idle)
    }

    @Test("Start skips rolling bodies; stop commands only rolling bodies")
    func startSkipsRollingStopTargetsRolling() async throws {
        var rolling = Self.movie
        rolling.recording = true
        let members = [Self.member(0), Self.member(1, facts: rolling), Self.member(2)]
        let group = try Self.group(members)
        let ids = group.entries.map(\.id)

        let start = RecordPlan.make(
            .start, policy: .eligibleSubset, entries: ids, in: group, at: Self.state(members))
        #expect(start.satisfied.map(\.entries) == [[ids[1]]])
        #expect(start.targets.map(\.entries) == [[ids[0]], [ids[2]]])

        let stop = RecordPlan.make(
            .stop, policy: .eligibleSubset, entries: ids, in: group, at: Self.state(members))
        #expect(stop.targets.map(\.entries) == [[ids[1]]])
        _ = try await stop.submit(
            in: group, at: Self.state(members), sessions: Self.sessions(members))
        for member in members { await Self.pump(member) }
        #expect(members[0].body.sent.isEmpty)
        #expect(members[1].body.sent == ["stop"])
        #expect(members[2].body.sent.isEmpty)
    }

    @Test("A lost link leaves that body's outcome unknown, never success")
    func lostLinkIsUnknown() async throws {
        let members = [Self.member(0), Self.member(1)]
        members[1].body.recordAnswer = .linkLost
        let group = try Self.group(members)
        let ids = group.entries.map(\.id)
        let plan = RecordPlan.make(
            .start, policy: .eligibleSubset, entries: ids, in: group, at: Self.state(members))
        let submission = try await plan.submit(
            in: group, at: Self.state(members), sessions: Self.sessions(members))
        for member in members { await Self.pump(member) }
        let result = await submission.finished(sessions: Self.sessions(members))
        #expect(result.outcome(for: ids[0], in: group) == .confirmed)
        #expect(result.outcome(for: ids[1], in: group) == .outcomeUnknown)
    }

    // MARK: Identity and eligibility

    @Test func qualificationPreservesSavedPathPolicy() {
        func verdict(_ path: CameraPath?, reachable: Bool = true, photo: Bool? = nil)
            -> MulticamQualification
        {
            NikonMulticamPolicy.qualification(
                path: path, reachable: reachable, isPhotography: photo, device: nil,
                members: [CameraDeviceID]())
        }
        for path: CameraPath in [.usbC, .infrastructure(networkName: "Set"), .phoneHotspot] {
            #expect(verdict(path) == .qualified)
        }
        #expect(verdict(.cameraAccessPoint(ssid: "test")) == .refused(.unsupportedConfiguration))
        #expect(verdict(.hdmiCapture) == .refused(.operationUnavailable))
        #expect(verdict(.usbC, photo: true) == .refused(.operationUnavailable))
        #expect(verdict(.usbC, reachable: false) == .refused(.notReachable))
        #expect(verdict(nil) == .refused(.notReachable))
        let device = CameraDeviceID.durable("test", integration: IntegrationID("test.cameras"))
        #expect(
            NikonMulticamPolicy.qualification(
                path: .usbC, reachable: true, isPhotography: false, device: device,
                members: [device])
                == .refused(.alreadyMember))
    }

    @Test func qualificationDoesNotInventUnknownCameraMode() {
        for path: CameraPath in [.usbC, .infrastructure(networkName: "Set"), .phoneHotspot] {
            func verdict(_ photo: Bool?) -> MulticamQualification {
                NikonMulticamPolicy.qualification(
                    path: path, reachable: true, isPhotography: photo, device: nil,
                    members: [CameraDeviceID]())
            }
            // Unknown mode permits opening this saved path, without asserting movie eligibility.
            #expect(verdict(nil) == .qualified)
            #expect(verdict(false) == .qualified)
            #expect(verdict(true) == .refused(.operationUnavailable))
        }
        #expect(
            NikonMulticamPolicy.qualification(
                path: .cameraAccessPoint(ssid: "test"), reachable: true, isPhotography: nil,
                device: nil, members: [CameraDeviceID]()) == .refused(.unsupportedConfiguration))
        let device = CameraDeviceID.durable("test", integration: IntegrationID("test.cameras"))
        #expect(
            NikonMulticamPolicy.qualification(
                path: .usbC, reachable: true, isPhotography: nil, device: device, members: [device])
                == .refused(.alreadyMember))
    }

    @Test("Member identity is the serial, not host or path")
    func identityIsTheSerial() {
        let usb = PTPIPSavedCameraRecord(
            host: "usb:zr", displayName: "ZR_1", transport: "USB-C", lastSeenAt: nil,
            serialNumber: "3000120",
            path: .usbC)
        let lan = PTPIPSavedCameraRecord(
            host: "192.168.1.20", displayName: "ZR_1", transport: "Wi-Fi", lastSeenAt: nil,
            serialNumber: " 3000120 ", path: .infrastructure(networkName: "Set"))
        let readdressed = PTPIPSavedCameraRecord(
            host: "192.168.1.77", displayName: "ZR_1", transport: "Wi-Fi", lastSeenAt: nil,
            serialNumber: "3000120", path: .infrastructure(networkName: "Set"))
        let device = NikonMulticamPolicy.device(serialNumber: usb.serialNumber)
        #expect(device != nil)
        #expect(NikonMulticamPolicy.device(serialNumber: lan.serialNumber) == device)
        #expect(NikonMulticamPolicy.device(serialNumber: readdressed.serialNumber) == device)
        // The entry and the body's own session name the same device.
        let member = Self.member(0)
        #expect(member.session.refresh().device == member.entry.device)

        // The same body over a second path is refused, whatever its host.
        for record in [lan, readdressed] {
            #expect(
                NikonMulticamPolicy.refusal(
                    path: record.path, reachable: true, isPhotography: false,
                    device: NikonMulticamPolicy.device(serialNumber: record.serialNumber),
                    members: [device!]) == .alreadyMember)
        }
        // A path saved before the serial stamp is admitted, then checked again by the serial its
        // session reports after connect.
        #expect(NikonMulticamPolicy.device(serialNumber: nil) == nil)
        #expect(NikonMulticamPolicy.device(serialNumber: "  ") == nil)
        #expect(
            NikonMulticamPolicy.refusal(
                path: .infrastructure(networkName: nil), reachable: true, isPhotography: false,
                device: nil, members: [device!]) == nil)
        #expect(
            NikonMulticamPolicy.refusal(
                path: .infrastructure(networkName: nil), reachable: true, isPhotography: false,
                device: NikonMulticamPolicy.device(serialNumber: "3000120"), members: [device!])
                == .alreadyMember)
    }

    @Test("USB-C, router and hotspot join; camera AP, HDMI, photography and offline are refused")
    func eligibility() {
        func refusal(_ path: CameraPath?, reachable: Bool = true, photo: Bool = false)
            -> NikonMulticamRefusal?
        {
            NikonMulticamPolicy.refusal(
                path: path, reachable: reachable, isPhotography: photo, device: nil,
                members: [CameraDeviceID]())
        }
        for path: CameraPath in [.usbC, .infrastructure(networkName: "Set"), .phoneHotspot] {
            #expect(refusal(path) == nil)
        }
        #expect(refusal(.cameraAccessPoint(ssid: "NIKON_ZR")) == .cameraAccessPoint)
        #expect(refusal(.hdmiCapture) == .hdmiCapture)
        #expect(refusal(.usbC, photo: true) == .photographyMode)
        #expect(refusal(.usbC, reachable: false) == .notReachable)
        #expect(refusal(nil) == .notReachable)
    }

    @Test("The member limit is the app's qualification budget, not an engine constant")
    func memberLimitIsAppPolicy() {
        let requests = (0..<5).map { index in
            ResourceRequest(
                entry: MonitorEntryID(),
                device: NikonMulticamPolicy.device(serialNumber: "300012\(index)"),
                claims: [.usbInterface("usb:\(index)")])
        }
        let qualified = ResourceBudget(qualifiedEntries: 4)
        #expect(
            ResourceAdmission.reasons(
                admitting: requests[3], alongside: Array(requests[0..<3]), budget: qualified
            )
            .isEmpty)
        #expect(
            ResourceAdmission.reasons(
                admitting: requests[4], alongside: Array(requests[0..<4]), budget: qualified)
                == [.overQualifiedLimit(4)])
        #expect(
            ResourceAdmission.reasons(
                admitting: requests[4], alongside: Array(requests[0..<4]),
                budget: ResourceBudget(qualifiedEntries: nil)
            ).isEmpty)
    }

    // MARK: Borrowing a member into full Live View

    @Test("Live View borrows a member and returns it: same session, its pump paused meanwhile")
    func borrowAndReturn() async throws {
        let members = (0..<3).map { Self.member($0) }
        var group = try Self.group(members)
        let ids = group.entries.map(\.id)
        let before = RecordPlan.make(
            .start, policy: .eligibleSubset, entries: ids, in: group, at: Self.state(members))

        // Borrow B: an editor/detail lease on its entry; its pump stands down and its stage
        // edits are reported not sent. The link stays open: nothing closes the session.
        var leases = EditorLeases()
        let lease = try leases.open(ids[1], in: group, at: Self.state(members))
        let queued = members[1].session.request(.set(.iso(.manual(1600)))).operation
        members[1].control.lend()
        #expect(members[1].session.receipt(of: queued)?.stage == .failed(.notSent))
        // The Live View's own pump owns the link now: this one queues and sends nothing.
        #expect(members[1].session.request(.set(.iso(.manual(3200)))).stage == .failed(.notSent))
        #expect(members[1].session.request(.startRecording).stage == .failed(.notSent))
        #expect(await Self.pump(members[1]).isEmpty)
        #expect(members[1].body.sent.isEmpty)

        // While lent, a group start leaves B to the Live View and commands the others.
        let borrowed = Self.state(members, busy: [ids[1]])
        let during = RecordPlan.make(
            .start, policy: .eligibleSubset, entries: ids, in: group, at: borrowed)
        #expect(during.exclusions == [Exclusion(entry: ids[1], reason: .busy)])
        #expect(during.targets.count == 2)

        // Return: same session ID and epoch (no CloseSession, no reconnect), so the plan made
        // before the loan is still current, and the lease is gone.
        leases.close(ids[1])
        members[1].control.reclaim()
        #expect(members[1].session.refresh().connection == .ready)
        #expect(before.isCurrent(in: group, at: Self.state(members)))
        #expect(leases.refusal(for: lease, in: group, at: Self.state(members)) == .retired)
        let after = members[1].session.request(.set(.iso(.manual(3200)))).operation
        await Self.pump(members[1])
        #expect(members[1].body.sent == ["write \(PTPPropertyCode.movieExposureIndex)"])
        #expect(members[1].session.receipt(of: after)?.stage == .confirmed)

        // A replacement session (a real reconnect) is what invalidates the plan.
        let replacement = Self.member(1)
        var entry = group[ids[1]]!
        entry.cameraSession = replacement.session.id
        try group.update(entry)
        #expect(
            !before.isCurrent(
                in: group, at: Self.state([members[0], replacement, members[2]])))
    }

    // MARK: Per-member writes

    @Test("Each member's writes go to its own link and are read back there", arguments: [2, 3, 4])
    func perMemberWrites(count: Int) async throws {
        let members = (0..<count).map { Self.member($0) }
        let iso = { (label: String) in
            PTPCameraPropertyWrite.isoWrite(label: label, dualBase: false)!
        }

        // A: two drum steps before the safe point; only the last one goes out and confirms.
        let first = members[0].session.request(.set(.iso(.manual(1000)))).operation
        let last = members[0].session.request(.set(.iso(.manual(1250)))).operation
        // B: the body clamps the value it was sent.
        members[1].body.clamps[iso("1600").property] = iso("1250").data
        let clamped = members[1].session.request(.set(.iso(.manual(1600)))).operation
        // C: the body refuses the write (control lock). D: the read after the write fails.
        var refused: OperationID?
        if count >= 3 {
            members[2].body.refusesWrites = [.movieWhiteBalance]
            refused = members[2].session.request(.set(.whiteBalance(.preset("Sunny")))).operation
        }
        var unread: OperationID?
        if count == 4 {
            members[3].body.readFails = true
            unread = members[3].session.request(.set(.iso(.manual(400)))).operation
        }

        var results: [[NikonMemberControl.WriteResult]] = []
        for member in members { results.append(await Self.pump(member)) }

        #expect(members[0].session.receipt(of: first)?.stage == .failed(.superseded))
        #expect(members[0].session.receipt(of: last)?.stage == .confirmed)
        #expect(results[0].map(\.outcome) == [.applied])
        #expect(members[0].control.nikonControlFacts.reported.iso == 1250)
        #expect(members[1].session.receipt(of: clamped)?.stage == .failed(.notApplied))
        #expect(results[1].map(\.outcome) == [.notApplied])
        #expect(members[1].control.nikonControlFacts.reported.iso == 1250, "the camera decides")
        if let refused {
            #expect(members[2].session.receipt(of: refused)?.stage == .rejected(.cameraRefused))
            #expect(results[2].map(\.outcome) == [.failed(refused: true)])
        }
        if let unread {
            #expect(members[3].session.receipt(of: unread)?.stage == .outcomeUnknown)
            #expect(results[3].map(\.outcome) == [.unknown])
        }
        // Nothing crossed to another member's link.
        for (index, member) in members.enumerated() {
            #expect(member.body.sent.count == 1, "member \(index) sent \(member.body.sent)")
            #expect(!member.control.hasQueuedCommands)
        }
    }
}
