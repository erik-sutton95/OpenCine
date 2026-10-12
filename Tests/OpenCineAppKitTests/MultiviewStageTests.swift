import OpenCineAppKit
import OpenCineCore
import OpenCineCoreTestSupport
import OpenCineMulticam
import Testing

/// SIMULATED. The shared Multiview stage on the shared engine: two and four cameras connect
/// through OpenCineCore's `FakeIntegration`, are admitted against the app's qualification budget,
/// fill the stage's four slots and record together through one confirmed plan. Every camera is a
/// `FakeCameraSession` on a manual clock. Kotlin mirror: `MultiviewStageTest`, same names.
@MainActor
@Suite struct MultiviewStageTests {
    static let slots = 4

    @Test func twoMemberStage() async throws { try await stage(members: 2) }
    @Test func fourMemberStage() async throws { try await stage(members: 4) }

    private func stage(members count: Int) async throws {
        // The app's qualification limit is a budget value, never an engine constant.
        let budget = ResourceBudget(qualifiedEntries: count)
        let integration = FakeIntegration()
        var cameras: [FakeCameraSession] = []
        integration.onAttempt = { attempt in
            let camera = FakeCameraSession.djiLike()
            cameras.append(camera)
            attempt.connect(session: camera)
        }
        let studio = SavedRoute(key: "studio", kind: .infrastructureNetwork, network: "Studio")

        var group = MulticamGroup()
        var requests: [ResourceRequest] = []
        for index in 0..<count {
            let name = "Camera \(MultiviewTile.letter(index))"
            let entry = MonitorEntryID()
            let request = ResourceRequest(entry: entry, device: nil, route: studio, picture: true)
            #expect(
                ResourceAdmission.reasons(
                    admitting: request, qualification: .qualified, alongside: requests,
                    budget: budget
                ).isEmpty)
            let connected = try #require(await connect(integration, name: name))
            requests.append(request)
            try group.add(
                MonitorEntryDescriptor(
                    id: entry, name: name, picture: PictureSourceDescriptor(label: name),
                    cameraSession: connected.session.id, telemetry: .cameraSession,
                    controlAuthority: .owner))
        }
        #expect(integration.attempts.count == count && cameras.count == count)
        // One more than the app qualified, or an unknown configuration, never joins.
        let extra = ResourceRequest(entry: MonitorEntryID(), device: nil, route: studio, picture: true)
        #expect(
            ResourceAdmission.reasons(
                admitting: extra, qualification: .qualified, alongside: requests, budget: budget)
                == [.overQualifiedLimit(count)])
        #expect(
            ResourceAdmission.reasons(
                admitting: extra, qualification: .unknown, alongside: Array(requests.dropLast()),
                budget: budget) == [.qualificationUnknown])

        func state() async -> MulticamSnapshot {
            var snapshots: [CameraSnapshot] = []
            for camera in cameras { snapshots.append(await camera.current) }
            return MulticamSnapshot(
                cameras: snapshots,
                pictures: Dictionary(
                    uniqueKeysWithValues: group.entries.compactMap { ($0.picture!.stream, PictureHealth.live) }),
                now: await cameras[0].now)
        }
        func tiles(_ state: MulticamSnapshot) -> [MultiviewTile?] {
            let summary = group.summary(at: state, telemetryMaxAge: .seconds(30))
            return (0..<Self.slots).map { slot in
                guard group.entries.indices.contains(slot) else { return nil }
                let entry = group.entries[slot]
                return MultiviewTile(
                    entry, summary: summary.entries[slot],
                    snapshot: entry.cameraSession.flatMap { state.cameras[$0] })
            }
        }
        func context() async -> MultiviewRecordContext {
            let now = await state()
            let direction: RecordDirection =
                group.summary(at: now, telemetryMaxAge: .seconds(30)).camerasRecording > 0
                ? .stop : .start
            return MultiviewRecordContext(
                plan: RecordPlan.make(
                    direction, policy: .strict, entries: group.entries.map(\.id), in: group, at: now))
        }
        let sessions = Dictionary(
            uniqueKeysWithValues: cameras.map { ($0.id, $0 as any CameraSession) })

        // Connected, nothing reported: every value stays unavailable and nothing records.
        var stage = tiles(await state())
        #expect(stage.count == Self.slots && stage.compactMap { $0 }.count == count)
        #expect(stage.compactMap { $0?.tally } == Array(repeating: "\u{2014}", count: count))
        #expect(stage.compactMap { $0 }.allSatisfy { $0.battery == nil && $0.timecode == nil })
        let waiting = await context()
        #expect(!waiting.canConfirm && waiting.plan.isRefused)
        #expect(waiting.plan.exclusions.first?.reason == .rejected(.supportUnknown))

        for camera in cameras { await camera.cameraReportsStatus() }
        stage = tiles(await state())
        let first = try #require(stage[0])
        #expect(first.name == "Camera A" && first.tally == "STBY" && first.battery == 76)
        #expect(first.timecode == "01:02:03" && first.status == nil)
        // A coarse observation carries the camera's gauge, never a percentage claim.
        let cameraID = try #require(group.entries[0].cameraSession)
        let observed = try #require((await state()).cameras[cameraID])
        var coarse = observed
        coarse.power.battery = ObservedValue(
            0.6, origin: .cameraReported, at: nil, precision: .quantized(step: 0.2))
        let gauge = MultiviewTile(group.entries[0], summary: group.summary(
            at: await state(), telemetryMaxAge: .seconds(30)).entries[0], snapshot: coarse)
        #expect(gauge.battery == nil)
        #expect(gauge.batteryBars == 3 && gauge.batteryBarCount == 5)
        #expect(first.batteryBars == nil)
        // The link as reported: a closed session is not connecting, and no report is a wait.
        var link = group.summary(at: await state(), telemetryMaxAge: .seconds(30)).entries[0]
        link.control = .reported(.disconnected(.linkLost))
        let lost = MultiviewTile(group.entries[0], summary: link, snapshot: nil)
        #expect(lost.status?.text == "Disconnected" && lost.status?.inProgress == false)
        link.control = .unreported
        #expect(
            MultiviewTile(group.entries[0], summary: link, snapshot: nil).detail
                == "Waiting for the camera")
        #expect(first.readouts.map(\.title) == ["ISO", "SHUTTER", "WB", "FOCUS"])
        #expect(first.readouts.map(\.value) == ["800", "1/50", "5600K", "\u{2014}"])
        #expect(stage[count...].allSatisfy { $0 == nil }, "the other slots stay empty")

        // One confirmed group start: one explicit command per camera, nothing else.
        let start = await context()
        #expect(start.canConfirm && !start.stopping)
        #expect(start.question(single: false) == "Record on all cameras?")
        let submission = try await start.plan.submit(in: group, at: await state(), sessions: sessions)
        for camera in cameras { await camera.advance(by: .seconds(1)) }
        let result = await submission.finished(sessions: sessions)
        #expect(result.confirmed == count)
        for camera in cameras { #expect(await camera.wire == ["record-toggle"]) }
        stage = tiles(await state())
        #expect(stage.compactMap { $0 }.allSatisfy { $0.recording && $0.tally == "REC" })
        let stop = await context()
        #expect(stop.stopping && stop.question(single: false) == "Stop recording on all cameras?")

        // Removing a member and closing its session sends nothing: it keeps recording, and so
        // do the others. No compensation, no stop on close.
        let last = try #require(group.entries.last)
        group.remove(last.id)
        await cameras[count - 1].close(.requested)
        stage = tiles(await state())
        #expect(stage.compactMap { $0 }.count == count - 1 && stage[count - 1] == nil)
        for camera in cameras {
            #expect(await camera.wire == ["record-toggle"])
            #expect(await camera.device.recording == true)
        }
    }

    /// The camera an attempt connects, or `nil` when it fails.
    private func connect(_ integration: FakeIntegration, name: String) async -> ConnectedCamera? {
        let sighting = NearbyCamera(
            id: name, name: name, model: "Test Body", routes: [.infrastructureNetwork])
        for await event in integration.connect(.nearby(sighting)) {
            if case .connected(let camera) = event { return camera }
        }
        return nil
    }
}
