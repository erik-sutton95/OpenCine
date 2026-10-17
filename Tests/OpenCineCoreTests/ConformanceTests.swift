import OpenCineCore
import OpenCineCoreTestSupport
import Testing

/// Plan section 11.2 cross-integration conformance scenarios, numbered as in the plan.
/// Scenarios that need native code, media analysis or discovery are disabled with the reason.
@Suite struct Conformance {
    @Test("1. Close is idempotent, stops nothing and leaves other sessions alone",
          arguments: Fixture.allCases)
    func closeIsIsolated(_ fixture: Fixture) async throws {
        let a = await reportedCamera(fixture)
        let b = await reportedCamera(fixture)
        _ = await a.submit(.startRecording)
        await a.advance(by: .seconds(10))
        #expect(await a.current.recording.value == .recording)
        let wireBeforeClose = await a.wire
        let feed = await a.snapshots()

        await a.close(.requested)
        await a.close(.requested)

        var last: CameraSnapshot?
        for await snapshot in feed { last = snapshot }
        #expect(last?.connection == .disconnected(.requested))
        #expect(await a.subscriberCount == 0)
        #expect(await a.wire == wireBeforeClose)
        #expect(await a.device.recording == true)
        #expect(await a.submit(.startRecording).stage == .rejected(.sessionClosed))
        var lateFeed = 0
        for await _ in await a.snapshots() { lateFeed += 1 }
        #expect(lateFeed == 1)

        #expect(await b.current.connection == .ready)
        let change = try #require(someChange(in: await b.current))
        let receipt = await b.submit(.set(change))
        await b.advance(by: .seconds(10))
        #expect(await b.outcome(of: receipt.operation)?.stage == .confirmed)
    }

    @Test("2. A late callback from attempt A cannot update attempt B", arguments: Fixture.allCases)
    func lateAttemptIgnored(_ fixture: Fixture) async {
        let camera = await reportedCamera(fixture)
        let attemptA = await camera.loseLink()
        let attemptB = await camera.beginAttempt()
        await camera.completeAttempt(attemptA)
        #expect(await camera.current.connection == .recovering(attemptB))
        let revision = await camera.current.revision
        await camera.cameraReportsStatus(from: attemptA)
        #expect(await camera.current.revision == revision)

        await camera.completeAttempt(attemptB)
        #expect(await camera.current.connection == .ready)
        #expect(await camera.current.epoch == ControlEpoch(2))
    }

    @Test(
        "3. Unknown recording, power, storage, timecode and audio levels remain unknown",
        arguments: Fixture.allCases)
    func unknownStaysUnknown(_ fixture: Fixture) async {
        let camera = fixture.make()
        let fresh = await camera.current
        #expect(fresh.recording == .unknown)
        #expect(fresh.power == .unknown)
        #expect(fresh.storage == .unknown)
        #expect(fresh.timecode == .unknown && fresh.audioLevels == .unknown)
        #expect(fresh.capabilities.timecode == .unknown)
        #expect(fresh.capabilities.audioLevels == .unknown)
        #expect(fresh.mode == .unknown)
        #expect(fresh.settings.isEmpty)
        #expect(SettingKey.allCases.allSatisfy { fresh.capabilities.support(of: $0) == .unknown })
        #expect(await camera.submit(.startRecording).stage == .rejected(.supportUnknown))

        await camera.cameraReportsStatus()
        let reported = await camera.current
        let device = await camera.device
        #expect(reported.power.charging == .unknown)
        #expect(reported.power.externalPower == .unknown)
        #expect(reported.power.battery.isKnown == (device.batteryPercent != nil))
        #expect(reported.storage.isKnown == (device.freeBytes != nil))
        #expect(reported.recording.origin == .cameraReported)
        // An observation is reported only where it is supported; a derived time says so.
        let capabilities = reported.capabilities
        #expect(capabilities.timecode != .unknown && capabilities.audioLevels != .unknown)
        #expect(reported.timecodeReading.isKnown == (capabilities.timecode == .supported && device.timecodeReading != nil))
        #expect(
            reported.audioLevels.isKnown
                == (capabilities.audioLevels == .supported && device.audioLevels != nil))
        #expect(!reported.timecodeReading.isKnown || [.cameraReported, .clockDerived].contains(reported.timecode.origin))
        #expect(!reported.audioLevels.isKnown || reported.audioLevels.origin == .cameraReported)
    }

    @Test("4. Values and domains follow the reported mode")
    func domainsFollowMode() async {
        let camera = await reportedCamera(.djiLike)
        let video = await camera.current
        #expect(video.mode.value?.role == .video)
        #expect(video.capabilities[.frameRate]?.accepts(.frameRate(Rational(24))) == true)

        await camera.cameraSwitchesMode(raw: 0x02)
        let slow = await camera.current
        #expect(slow.capabilities.revision > video.capabilities.revision)
        #expect(slow.capabilities[.frameRate]?.accepts(.frameRate(Rational(24))) == false)
        #expect(slow.value(of: .frameRate).value == .frameRate(Rational(120)))
        #expect(await camera.submit(.set(.frameRate(Rational(24)))).stage == .rejected(.outOfDomain))

        await camera.cameraSwitchesMode(raw: 0x05)
        let photo = await camera.current
        #expect(photo.mode.value?.role == .photo)
        #expect(photo.capabilities.support(of: .frameRate) == .unsupported)
        #expect(photo.value(of: .frameRate) == .unknown)
        #expect(await camera.submit(.startRecording).stage == .rejected(.unavailable(.mode)))

        await camera.cameraSwitchesMode(raw: 0x7F)
        let unmapped = await camera.current
        #expect(unmapped.mode.value?.role == .other)
        #expect(unmapped.capabilities.support(of: .iso) == .unknown)
        #expect(await camera.submit(.set(.iso(.manual(800)))).stage == .rejected(.supportUnknown))
        #expect(await camera.wire.isEmpty)
    }

    @Test("5. A read-only setting never becomes writable because a view asked")
    func readOnlyStaysReadOnly() async {
        let camera = await reportedCamera(.lunaLike)
        let capabilities = await camera.current.capabilities
        #expect(capabilities[.aperture]?.access == .readOnly)
        #expect(await camera.current.value(of: .aperture).value == .aperture(2))
        #expect(await camera.submit(.set(.aperture(2))).stage == .rejected(.readOnly))
        #expect(await camera.current.capabilities == capabilities)
        #expect(await camera.wire.isEmpty)
        #expect(MonitorLayoutCapabilities(capabilities).iris == false)
    }

    @Test("6. Accepted stays pending until readback", arguments: Fixture.allCases)
    func pendingUntilReadback(_ fixture: Fixture) async throws {
        let camera = await reportedCamera(fixture)
        let before = await camera.current
        let change = try #require(someChange(in: before))
        let receipt = await camera.submit(.set(change))
        #expect(receipt.stage == .awaitingObservation)
        #expect(await camera.current.value(of: change.key) == before.value(of: change.key))

        await camera.advance(by: camera.behavior.reportDelay - .milliseconds(1))
        #expect(await camera.stages(of: receipt.operation).last == .awaitingObservation)

        await camera.advance(by: .seconds(10))
        #expect(await camera.outcome(of: receipt.operation)?.stage == .confirmed)
        #expect(
            await camera.stages(of: receipt.operation) == [
                .created, .admitted, .sent, .accepted, .awaitingObservation, .confirmed,
            ])
        let observed = await camera.current.value(of: change.key)
        #expect(observed.value == change)
        #expect(observed.origin == .cameraReported)
    }

    @Test("6. Rejection and timeout stay distinguishable", arguments: Fixture.allCases)
    func rejectionVersusTimeout(_ fixture: Fixture) async throws {
        let camera = await reportedCamera(fixture)
        let before = await camera.current
        let change = try #require(someChange(in: before))

        await camera.refuseNextCommand()
        #expect(await camera.submit(.set(change)).stage == .rejected(.cameraRefused))

        await camera.silenceReports(true)
        let silent = await camera.submit(.set(change))
        await camera.advance(by: .seconds(30))
        #expect(await camera.outcome(of: silent.operation)?.stage == .timedOut)
        #expect(await camera.current.value(of: change.key) == before.value(of: change.key))

        // The camera did act. Its next report shows it; the timed-out receipt stays timed out.
        await camera.silenceReports(false)
        await camera.cameraReportsStatus()
        #expect(await camera.current.value(of: change.key).value == change)
        #expect(await camera.outcome(of: silent.operation)?.stage == .timedOut)
    }

    @Test("6. Multi-second settle, and accepted without a stored change")
    func settleAndNotApplied() async {
        let camera = await reportedCamera(.lunaLike)
        let settled = await camera.submit(.set(.whiteBalance(.kelvin(5600))))
        await camera.advance(by: .seconds(2))
        #expect(await camera.stages(of: settled.operation).last == .awaitingObservation)
        await camera.advance(by: .seconds(1))
        #expect(await camera.outcome(of: settled.operation)?.stage == .confirmed)

        await camera.dropNextWrite()
        let dropped = await camera.submit(.set(.whiteBalance(.kelvin(3200))))
        #expect(dropped.stage == .awaitingObservation)
        await camera.advance(by: .seconds(3))
        #expect(await camera.outcome(of: dropped.operation)?.stage == .failed(.notApplied))
        #expect(await camera.current.value(of: .whiteBalance).value == .whiteBalance(.kelvin(5600)))
    }

    @Test("6. A newer write to the same setting supersedes an unfinished one", arguments: Fixture.allCases)
    func newerWriteSupersedes(_ fixture: Fixture) async throws {
        let camera = await reportedCamera(fixture)
        let before = await camera.current
        let first = try #require(someChange(in: before))
        let second = try #require(
            before.capabilities[first.key]?.domain?.choices.first {
                $0 != first && $0 != before.value(of: first.key).value
            })
        let older = await camera.submit(.set(first))
        let newer = await camera.submit(.set(second))
        #expect(older.stage == .awaitingObservation)
        #expect(await camera.receipt(of: older.operation)?.stage == .failed(.superseded))

        await camera.advance(by: .seconds(10))
        #expect(await camera.outcome(of: older.operation)?.stage == .failed(.superseded))
        #expect(await camera.outcome(of: newer.operation)?.stage == .confirmed)
        #expect(await camera.current.value(of: first.key).value == second)
    }

    @Test("6. A deadline bounds the wait without inventing state")
    func deadlineBoundsWait() async {
        let camera = await reportedCamera(.djiLike)
        let command = await camera.command(
            .set(.iso(.manual(1600))), deadline: MonotonicInstant.zero + .milliseconds(100))
        _ = await camera.submit(command)
        await camera.advance(by: .seconds(1))
        #expect(await camera.outcome(of: command.operation)?.stage == .timedOut)
        #expect(await camera.current.value(of: .iso).value == .iso(.manual(1600)))
        let late = CameraCommand(command.intent, preconditions: command.preconditions)
        #expect(await camera.submit(late).stage == .rejected(.deadlinePassed))
    }

    @Test("7. A capability change retires stale editor commands", arguments: Fixture.allCases)
    func capabilityChangeRetiresEdits(_ fixture: Fixture) async throws {
        let camera = await reportedCamera(fixture)
        let change = try #require(someChange(in: await camera.current))
        let queued = await camera.command(.set(change))
        let original = await camera.device.rawMode
        await camera.cameraSwitchesMode(raw: 0x7F)
        await camera.cameraSwitchesMode(raw: original)

        #expect(await camera.submit(queued).stage == .rejected(.staleCapabilities))
        #expect(await camera.wire.isEmpty)
        #expect(await camera.submit(.set(change)).stage == .awaitingObservation)
    }

    @Test("8. Commands cannot reach another camera, a replacement link or a replaced lease",
          arguments: Fixture.allCases)
    func commandsStayBound(_ fixture: Fixture) async throws {
        let a = await reportedCamera(fixture)
        let b = await reportedCamera(fixture)
        let change = try #require(someChange(in: await a.current))
        let forA = await a.command(.set(change))
        #expect(await b.submit(forA).stage == .rejected(.wrongSession))

        let attempt = await a.loseLink()
        let retry = { CameraCommand(.set(change), preconditions: forA.preconditions) }
        #expect(await a.submit(retry()).stage == .rejected(.notConnected))
        await a.completeAttempt(attempt)
        #expect(await a.submit(retry()).stage == .rejected(.staleEpoch))

        await a.setAuthority(.lease(ControlLease()))
        let leased = await a.command(.set(change))
        await a.setAuthority(.lease(ControlLease()))
        #expect(await a.submit(leased).stage == .rejected(.noAuthority))
        #expect(await a.wire.isEmpty)
        #expect(await b.wire.isEmpty)
    }

    @Test("9. A picture failure does not fabricate a stopped recording", arguments: Fixture.allCases)
    func pictureFailureKeepsRecording(_ fixture: Fixture) async throws {
        let camera = await reportedCamera(fixture)
        var picture = FakePictureSource(label: "Live view")
        picture.start()
        let entry = MonitorEntryDescriptor(
            name: "A", picture: picture.descriptor, cameraSession: camera.id,
            telemetry: .cameraSession, controlAuthority: .owner)
        _ = await camera.submit(.startRecording)
        await camera.advance(by: .seconds(10))
        #expect(await camera.current.recording.value == .recording)

        picture.fail()
        #expect(picture.health == .failed)
        #expect(await camera.current.recording.value == .recording)
        try entry.validate()

        // A lost control link keeps the last report and its age, not idle.
        await camera.loseLink()
        await camera.advance(by: .seconds(30))
        let recording = await camera.current.recording
        #expect(recording.value == .recording)
        #expect(recording.freshness(at: await camera.now, maxAge: .seconds(5)) == .stale)
    }

    @Test("10. Camera commands work while another picture source is displayed")
    func controlSurvivesPictureSwap() async throws {
        let camera = FakeCameraSession.nikonLike()
        await camera.cameraReportsStatus()
        var liveView = FakePictureSource(label: "Camera")
        liveView.start()
        var entry = MonitorEntryDescriptor(
            name: "Z", picture: liveView.descriptor, cameraSession: camera.id,
            telemetry: .cameraSession, controlAuthority: .owner)
        let before = await camera.current

        var hdmi = FakePictureSource(label: "HDMI")
        hdmi.start()
        entry.picture = hdmi.descriptor
        try entry.validate()
        #expect(entry.cameraSession == camera.id)
        let after = await camera.current
        #expect(after.session == before.session)
        #expect(after.epoch == before.epoch)

        let iso = await camera.submit(.set(.iso(.manual(1600))))
        await camera.advance(by: .seconds(1))
        #expect(await camera.outcome(of: iso.operation)?.stage == .confirmed)

        // Recording needs the camera's own live view, said with a typed reason.
        #expect(await camera.submit(.startRecording).stage == .rejected(.unavailable(.notReady)))
        await camera.setLiveViewReady(true)
        let start = await camera.submit(.startRecording)
        await camera.advance(by: .seconds(1))
        #expect(await camera.outcome(of: start.operation)?.stage == .confirmed)
        #expect(await camera.wire.last == "record-start")

        // Acknowledgement-only control: accepted is finished, never "confirmed".
        let focus = await camera.submit(.focusPoint(x: 0.5, y: 0.5))
        #expect(focus.stage == .accepted)
        #expect(focus.isFinished)
        #expect(await camera.submit(.focusPoint(x: 1.5, y: 0.5)).stage == .rejected(.outOfDomain))
    }

    @Test("11. Session owners receive only their own native events",
          .disabled("N/A for CORE-01: no native or JNI code exists here; STATE-01 and CORE-02"))
    func nativeEventsStayWithTheirOwner() {}

    @Test("12. Profile, false-color and EV calibration configurations are isolated",
          .disabled("N/A for CORE-01: analysis and calibration state belong to MEDIA-01/STATE-01"))
    func analysisConfigurationsAreIsolated() {}

    @Test("13. Lease expiry blocks commands but keeps picture-only access",
          arguments: Fixture.allCases)
    func leaseExpiry(_ fixture: Fixture) async throws {
        let camera = await reportedCamera(fixture)
        let lease = ControlLease(expiresAt: await camera.now + .seconds(10))
        await camera.setAuthority(.lease(lease))
        var relay = FakePictureSource(label: "Relay")
        relay.start()
        let entry = MonitorEntryDescriptor(
            name: "Relay", picture: relay.descriptor, cameraSession: camera.id, telemetry: .relay,
            controlAuthority: .lease(lease))
        try entry.validate()

        let change = try #require(someChange(in: await camera.current))
        #expect(await camera.submit(.set(change)).stage == .awaitingObservation)
        await camera.advance(by: .seconds(11))
        #expect(await camera.submit(.set(change)).stage == .rejected(.authorityExpired))

        var viewer = entry
        viewer.controlAuthority = .readOnly
        try viewer.validate()
        #expect(viewer.picture == relay.descriptor)
        #expect(relay.health == .live)
    }

    @Test("14. Start/stop retries follow idempotency, never a blind toggle",
          arguments: Fixture.allCases)
    func recordRetries(_ fixture: Fixture) async throws {
        let camera = await reportedCamera(fixture)
        let start = await camera.command(.startRecording)
        _ = await camera.submit(start)
        _ = await camera.submit(start)
        await camera.advance(by: .seconds(10))
        #expect(await camera.outcome(of: start.operation)?.stage == .confirmed)
        #expect(await camera.wire.count == 1)

        #expect(await camera.submit(.startRecording).stage == .confirmed)
        #expect(await camera.wire.count == 1)
        #expect(await camera.device.recording == true)

        let stop = await camera.submit(.stopRecording)
        await camera.advance(by: .seconds(10))
        #expect(await camera.outcome(of: stop.operation)?.stage == .confirmed)
        #expect(await camera.current.recording.value == .idle)
        #expect(await camera.wire.count == 2)
    }

    @Test("14. Unknown recording state blocks only toggle wires", arguments: Fixture.allCases)
    func unknownRecordingState(_ fixture: Fixture) async {
        let template = fixture.make()
        var device = await template.device
        device.recording = nil
        let camera = FakeCameraSession(behavior: template.behavior, device: device)
        await camera.cameraReportsStatus()
        await camera.setLiveViewReady(true)
        #expect(await camera.current.recording == .unknown)

        let receipt = await camera.submit(.startRecording)
        switch camera.behavior.recordWire {
        case .toggle:
            #expect(receipt.stage == .rejected(.recordingStateUnknown))
            #expect(await camera.wire.isEmpty)
        case .explicit:
            await camera.advance(by: .seconds(10))
            #expect(await camera.outcome(of: receipt.operation)?.stage == .confirmed)
            #expect(await camera.wire == ["record-start"])
        }
    }

    /// Against the scripted integration; each integration runs it with its own fake transports.
    @MainActor
    @Test("15. Discovery follows passive/active policy")
    func discoveryFollowsPolicy() async {
        let both = FakeIntegration(discoveryModes: [.passive, .active], endpoints: ["10.0.0.2", "10.0.0.3"])
        var passive = both.discover(.passive).makeAsyncIterator()
        _ = await passive.next()
        #expect(!both.dials.isEmpty)
        #expect(both.dials.allSatisfy { $0.purpose == .presence })

        var active = both.discover(.active).makeAsyncIterator()
        _ = await active.next()
        #expect(both.dials.filter { $0.purpose == .cameraControl }.map(\.endpoint) == ["10.0.0.2", "10.0.0.3"])
        #expect(both.discoveries == [.passive, .active])

        // An integration that only listens never runs an active discovery.
        let listening = FakeIntegration(discoveryModes: [.passive], endpoints: ["10.0.0.2"])
        for await _ in listening.discover(.active) { Issue.record("active ran") }
        #expect(listening.dials.isEmpty)
    }
}
