import Foundation
import OpenCineAppKit
import OpenCineCore
import OpenCineCoreTestSupport
import Testing

/// The shell's root state and monitor lifetime through the shared interface: a scripted
/// integration, fake sessions on manual clocks. Kotlin mirror: `ShellModelTest`, same names.
@MainActor
@Suite struct ShellModelTests {
    typealias T = CamerasModelTests
    let fake = FakeIntegration(id: IntegrationID("test.cameras"))
    let clock = ManualClock()

    static let other = SavedCamera(
        id: "camera-2", integration: IntegrationID("test.cameras"), advertisedName: "CAM-2", model: "Test Body",
        routes: [T.ap], preferredRoute: T.ap.id)

    @available(macOS 14, *)
    func shell(saved: [SavedCamera] = [T.camera, Self.other]) -> ShellModel {
        let store = SavedCamerasStore(document: Defaults([:]).at("document"))
        store.save(saved)
        let cameras = CamerasModel(integrations: [AppIntegration(fake)], store: store)
        return ShellModel(cameras: cameras, control: MonitorControlModel(sleep: { [clock] in await clock.sleep($0) }))
    }

    /// Connects `camera` through the connection model with `session`.
    @available(macOS 14, *)
    func connect(_ shell: ShellModel, _ camera: SavedCamera, _ session: any CameraSession) async -> Bool {
        shell.cameras.connect(camera)
        fake.liveAttempt(for: camera.id)?.connect(session: session)
        return await eventually { shell.monitor?.session.id == session.id }
    }

    @available(macOS 14, *)
    @Test func routesFollowSavedCamerasPairingAndTheMonitor() async {
        #expect(shell(saved: []).route == .pair)
        let empty = shell(saved: [])
        empty.showCameras()
        #expect(empty.route == .cameras, "the operator chose the list")
        empty.beginPairing()
        #expect(empty.route == .pair)
        let shell = shell()
        #expect(shell.route == .cameras)
        shell.beginPairing()
        #expect(shell.route == .pair)
        shell.open(.settings)
        let camera = Counted(FakeCameraSession.lunaLike())
        #expect(await connect(shell, T.camera, camera))
        #expect(shell.route == .monitor && !shell.pairing && shell.cover == nil, "connecting ends pairing and covers")
        shell.close()
        #expect(shell.route == .cameras)
    }

    /// Hardware pass 8.0: the Local Network prompt and a Settings visit both take the scene
    /// inactive; coming back re-checks a Local Network failure by connecting again, once.
    @available(macOS 14, *)
    @Test func becomingActiveRechecksALocalNetworkFailure() async {
        let shell = shell()
        shell.cameras.connect(T.camera)
        fake.attempts[0].fail(T.localNetworkDenied)
        #expect(await eventually { shell.cameras.failures[T.camera.id] != nil })
        shell.setSceneActive(true)
        #expect(fake.attempts.count == 1, "no change of activity, no re-check")
        shell.setSceneActive(false)
        #expect(fake.attempts.count == 1)
        shell.setSceneActive(true)
        #expect(fake.attempts.count == 2 && shell.cameras.failures.isEmpty)
    }

    /// One integration is one backend: a re-check dials one of its cameras, never two at once.
    @available(macOS 14, *)
    @Test func aRecheckDialsOneCameraPerIntegration() async {
        let shell = shell()
        shell.cameras.connect(T.camera)
        fake.attempts[0].fail(T.localNetworkDenied)
        shell.cameras.connect(Self.other)
        fake.attempts[1].fail(T.localNetworkDenied)
        #expect(await eventually { shell.cameras.failures.count == 2 })
        shell.setSceneActive(false)
        shell.setSceneActive(true)
        #expect(fake.attempts.count == 3 && shell.cameras.attempts.count == 1)
    }

    /// A live camera is never replaced by a re-check of an older failure (CodeRabbit, #262).
    @available(macOS 14, *)
    @Test func aRecheckLeavesALiveCameraAlone() async {
        let shell = shell()
        shell.cameras.connect(T.camera)
        fake.attempts[0].fail(T.localNetworkDenied)
        #expect(await eventually { shell.cameras.failures[T.camera.id] != nil })
        #expect(await connect(shell, Self.other, Counted(FakeCameraSession.lunaLike())))
        shell.setSceneActive(false)
        shell.setSceneActive(true)
        #expect(fake.attempts.count == 2, "the live camera keeps its session")
    }

    @available(macOS 14, *)
    @Test func connectAThenReplaceWithBAndDeliverALate() async {
        let shell = shell()
        let a = Counted(FakeCameraSession.lunaLike())
        let b = Counted(FakeCameraSession.lunaLike())
        await a.fake.cameraReportsStatus()
        await b.fake.cameraReportsStatus()
        #expect(await connect(shell, T.camera, a))
        #expect(await eventually { shell.control.snapshot?.session == a.id })
        shell.control.set(.iso(.manual(800)), label: "ISO 800")
        await clock.tick(.milliseconds(120))
        #expect(await eventuallyAsync { await a.fake.wire.count == 1 })
        let first = shell.monitor?.id

        #expect(await connect(shell, Self.other, b))
        #expect(shell.monitor?.id != first && shell.cameras.connected?.session.id == b.id)
        #expect(await eventuallyAsync { await a.closes == [.replaced] })
        // A answers late, and reports again: nothing reaches B's monitor.
        await a.fake.advance(by: .seconds(10))
        await a.fake.cameraReportsStatus()
        for _ in 0..<200 { await Task.yield() }
        #expect(shell.monitor?.session.id == b.id && shell.control.session?.id == b.id)
        #expect(shell.control.snapshot?.session == b.id && shell.control.pending.isEmpty)
        #expect(await b.closes.isEmpty)
    }

    @available(macOS 14, *)
    @Test func presentingTheSameSessionPreservesTheMonitorLifetime() async throws {
        let shell = shell()
        let camera = Counted(FakeCameraSession.lunaLike())
        await camera.fake.cameraReportsStatus()
        #expect(await connect(shell, T.camera, camera))
        #expect(await eventually { shell.control.captureField(.iso)?.isEditable == true })
        let first = try #require(shell.monitor)
        let editor = try #require(shell.control.edit(.iso))
        shell.open(.settings)
        shell.present(first.camera)
        for _ in 0..<200 { await Task.yield() }
        #expect(shell.monitor?.id == first.id && shell.cover == .settings)
        #expect(shell.control.isCurrent(editor))
        #expect(await camera.closes.isEmpty)
    }

    @available(macOS 14, *)
    @Test func closeOnce() async {
        let shell = shell()
        let camera = Counted(FakeCameraSession.lunaLike())
        #expect(await connect(shell, T.camera, camera))
        shell.close()
        shell.close()
        #expect(await eventuallyAsync { await camera.closes == [.requested] })
        for _ in 0..<200 { await Task.yield() }
        #expect(await camera.closes == [.requested])
        #expect(shell.monitor == nil && shell.cameras.connected == nil && shell.control.session == nil)
        #expect(await eventually { fake.liveDiscoveries == [.passive] }, "discovery resumes")
    }

    @available(macOS 14, *)
    @Test func disconnectDuringPendingEdit() async {
        let shell = shell()
        let notes = Notes()
        shell.control.onNote = { notes.list.append($0) }
        let camera = Counted(FakeCameraSession.lunaLike())
        await camera.fake.cameraReportsStatus()
        #expect(await connect(shell, T.camera, camera))
        #expect(await eventually { shell.control.snapshot?.mode.isKnown == true })
        shell.control.set(.iso(.manual(800)), label: "ISO 800")
        // The session ends on its own (the integration gave up the link) before the edit is sent.
        await camera.close(.linkLost)
        #expect(await eventually { shell.monitor == nil })
        #expect(shell.control.pending.isEmpty && shell.cameras.connected == nil)
        clock.advance(by: .seconds(1))
        for _ in 0..<200 { await Task.yield() }
        #expect(await camera.fake.wire.isEmpty)
        #expect(notes.list.isEmpty)
        #expect(await camera.closes == [.linkLost], "the shell does not close it again")
    }

    @available(macOS 14, *)
    @Test func closeWhileRecordingSendsNoStop() async {
        let shell = shell()
        let fakeSession = FakeCameraSession.lunaLike()
        let camera = Counted(fakeSession)
        await fakeSession.cameraReportsStatus()
        #expect(await connect(shell, T.camera, camera))
        shell.control.record(start: true)
        #expect(await eventuallyAsync { await fakeSession.wire == ["record-start"] })
        await fakeSession.advance(by: .seconds(3))
        #expect(await eventually { shell.control.isRecording == true })
        shell.close()
        #expect(await eventuallyAsync { await camera.closes == [.requested] })
        #expect(await fakeSession.wire == ["record-start"])
        #expect(await fakeSession.device.recording == true, "the camera keeps recording")
    }

    @available(macOS 14, *)
    @Test func coverAndRevealPreserveTheHostAndConnection() async {
        let shell = shell()
        let camera = Counted(FakeCameraSession.lunaLike())
        await camera.fake.cameraReportsStatus()
        #expect(await connect(shell, T.camera, camera))
        let host = shell.monitor?.id
        shell.open(.settings)
        #expect(shell.route == .monitor && shell.cover == .settings && shell.monitor?.id == host)
        shell.dismissCover()
        shell.open(.media)
        shell.dismissCover()
        #expect(shell.cover == nil && shell.monitor?.id == host && shell.control.session?.id == camera.id)
        for _ in 0..<200 { await Task.yield() }
        #expect(await camera.closes.isEmpty)
        // Leaving the monitor drops a cover with it; the cameras page has its own covers.
        shell.open(.media)
        shell.close()
        #expect(shell.cover == nil)
        shell.open(.settings)
        #expect(shell.route == .cameras && shell.cover == .settings)
    }

    @available(macOS 14, *)
    @Test func cameraGalleryOpensAndClosesOnlyTheMediaCover() {
        let shell = shell()
        shell.followCameraGallery(open: true)
        #expect(shell.cover == .media)
        shell.followCameraGallery(open: false)
        #expect(shell.cover == nil)
        shell.open(.settings)
        shell.followCameraGallery(open: true)
        #expect(shell.cover == .settings)
        shell.followCameraGallery(open: false)
        #expect(shell.cover == .settings)
    }

    /// A2-07: an internet hop leaves the monitor with the gallery cover still open, so the
    /// cover page (and its scroll, filter and selection) is never torn down and rebuilt.
    @available(macOS 14, *)
    @Test func leavingTheMonitorCanRetainItsCover() async {
        let shell = shell()
        let camera = Counted(FakeCameraSession.lunaLike())
        await camera.fake.cameraReportsStatus()
        #expect(await connect(shell, T.camera, camera))
        shell.open(.media)
        shell.close(.retain)
        #expect(shell.monitor == nil && shell.route == .cameras)
        #expect(shell.cover == .media, "the cover is never cleared, so its page keeps its identity")
        #expect(await eventuallyAsync { await camera.closes == [.requested] })
    }

    @available(macOS 14, *)
    @Test func liveLinkLossRetainsTheHeldPicture() async throws {
        let shell = shell()
        let fakeSession = FakeCameraSession.lunaLike()
        await fakeSession.cameraReportsStatus()
        #expect(await connect(shell, T.camera, Counted(fakeSession)))
        #expect(await eventually { shell.control.shown(.iso) == .iso(.manual(200)) })
        let host = shell.monitor?.id
        let editor = try #require(shell.control.edit(.iso))
        let attempt = await fakeSession.loseLink()
        #expect(await eventually {
            if case .recovering = shell.control.snapshot?.connection { return true }
            return false
        })
        #expect(shell.monitor?.id == host, "recovery is the integration's: the monitor stays")
        #expect(shell.control.shown(.iso) == .iso(.manual(200)), "last reported values are held")
        await fakeSession.completeAttempt(attempt)
        #expect(await eventually { shell.control.snapshot?.connection == .ready })
        #expect(!shell.control.isCurrent(editor), "a new control epoch obsoletes the editor")
        #expect(shell.monitor?.id == host)
    }

    @available(macOS 14, *)
    @Test func staleRecordReceiptCannotOverwriteTheReplacementSession() async {
        let shell = shell()
        let a = FakeCameraSession.lunaLike()
        let b = FakeCameraSession.lunaLike()
        await a.cameraReportsStatus()
        await b.cameraReportsStatus()
        var finished: [CameraSessionID] = []
        shell.control.onRecordFinished = { finished.append($0.session) }
        #expect(await connect(shell, T.camera, Counted(a)))
        shell.control.record(start: true)
        #expect(await eventuallyAsync { await a.wire == ["record-start"] })
        #expect(await connect(shell, Self.other, Counted(b)))
        #expect(!shell.control.recordPending)
        await a.advance(by: .seconds(3))
        for _ in 0..<200 { await Task.yield() }
        #expect(finished.isEmpty && !shell.control.recordPending)
        shell.control.record(start: true)
        #expect(await eventuallyAsync { await b.wire == ["record-start"] })
        await b.advance(by: .seconds(3))
        #expect(await eventually { finished == [b.id] })
    }

    @available(macOS 14, *)
    @Test func borrowAndReturnDoesNotCloseItsOwner() async {
        let shell = shell()
        let fakeSession = FakeCameraSession.lunaLike()
        let member = Counted(fakeSession)
        await fakeSession.cameraReportsStatus()
        var released = 0
        shell.borrow(ConnectedCamera(saved: T.camera, session: member)) { released += 1 }
        #expect(shell.route == .monitor && shell.monitor?.isBorrowed == true)
        #expect(await eventually { shell.control.snapshot?.session == member.id })
        shell.open(.settings)
        shell.close()
        shell.close()
        #expect(released == 1 && shell.monitor == nil)
        for _ in 0..<200 { await Task.yield() }
        #expect(await member.closes.isEmpty)
        #expect(await fakeSession.wire.isEmpty)
        #expect(await fakeSession.current.connection == .ready)
    }

    @available(macOS 14, *)
    @Test func sceneActivityIsReportedOncePerChange() {
        let shell = shell()
        var reports: [Bool] = []
        shell.onSceneActivity = { reports.append($0) }
        shell.setSceneActive(true)
        shell.setSceneActive(false)
        shell.setSceneActive(false)
        shell.setSceneActive(true)
        shell.setSceneActive(true)
        #expect(reports == [false, true])
    }
}

/// A session that records every close it receives, over a fake.
actor Counted: CameraSession {
    nonisolated let fake: FakeCameraSession
    nonisolated var id: CameraSessionID { fake.id }
    private(set) var closes: [SessionCloseReason] = []

    init(_ fake: FakeCameraSession) { self.fake = fake }

    func snapshots() async -> AsyncStream<CameraSnapshot> { await fake.snapshots() }
    func submit(_ command: CameraCommand) async -> CommandReceipt { await fake.submit(command) }
    func outcome(of operation: OperationID) async -> CommandReceipt? { await fake.outcome(of: operation) }
    func receipt(of operation: OperationID) async -> CommandReceipt? { await fake.receipt(of: operation) }
    func close(_ reason: SessionCloseReason) async {
        closes.append(reason)
        await fake.close(reason)
    }
}
