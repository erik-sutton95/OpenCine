import Foundation
import OpenCineCore
import OpenCineCoreTestSupport
import Testing

@Suite struct Values {
    @Test func unknownTelemetryIsNeverCoerced() throws {
        #expect(ObservedValue<Double>.unknown.value == nil)
        #expect(ObservedValue<Bool>.unknown != ObservedValue(false, origin: .cameraReported, at: .zero))
        #expect(ObservedValue<Double>.unknown != ObservedValue(0, origin: .cameraReported, at: .zero))
        #expect(ObservedValue<String>.unknown != ObservedValue("", origin: .cameraReported, at: .zero))
        #expect(ObservedValue<Double>.unknown.freshness(at: .zero, maxAge: .seconds(1)) == .unknown)

        let snapshot = CameraSnapshot(session: CameraSessionID())
        #expect(snapshot.recording.value == nil)
        #expect(snapshot.power == .unknown)
        #expect(snapshot.storage.value == nil)
        #expect(snapshot.timecode.value == nil && snapshot.audioLevels.value == nil)
        #expect(snapshot.capabilities.timecode == .unknown)
        #expect(snapshot.capabilities.audioLevels == .unknown)

        // Serialization keeps unknown unknown.
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(CameraSnapshot.self, from: data)
        #expect(decoded == snapshot)
        #expect(decoded.power.battery.value == nil)
    }

    @Test func freshnessIsComputedFromAge() {
        let battery = ObservedValue(0.5, origin: .cameraReported, at: .zero)
        #expect(battery.freshness(at: .zero + .seconds(1), maxAge: .seconds(2)) == .fresh)
        #expect(battery.freshness(at: .zero + .seconds(3), maxAge: .seconds(2)) == .stale)
        let undated = ObservedValue(0.5, origin: .imageEstimated, at: nil)
        #expect(undated.freshness(at: .zero, maxAge: .seconds(2)) == .unknown)
    }

    /// MULTI-03 F1: every caller reads one process reference, so instants taken by different
    /// sessions compare.
    @Test func nowIsOneMonotonicReference() {
        let first = MonotonicInstant.now()
        let second = MonotonicInstant.now()
        #expect(first <= second)
        #expect(second - first < .seconds(1))
    }

    @Test func rationalsAreNormalized() throws {
        #expect(Rational(2, 100) == Rational(1, 50))
        #expect(Rational(1, -3) == Rational(-1, 3))
        #expect(Rational(0, 7) == Rational(0))
        #expect(Rational(24000, 1001).denominator == 1001)
        let decoded = try JSONDecoder().decode(
            Rational.self, from: Data(#"{"numerator":2,"denominator":100}"#.utf8))
        #expect(decoded == Rational(1, 50))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                Rational.self, from: Data(#"{"numerator":1,"denominator":0}"#.utf8))
        }
    }

    @Test func domainsValidateChoicesRangesAndKeys() {
        let iso = SettingDescriptor(
            .iso, domain: SettingDomain(choices: [.iso(.auto), .iso(.manual(400)), .iso(.manual(800))]))
        #expect(iso.accepts(.iso(.manual(800))))
        #expect(iso.accepts(.iso(.auto)))
        #expect(!iso.accepts(.iso(.manual(500))))

        let wb = SettingDescriptor(
            .whiteBalance,
            domain: SettingDomain(choices: [.whiteBalance(.auto)], range: 2000...10000, step: 100))
        #expect(wb.accepts(.whiteBalance(.auto)))
        #expect(wb.accepts(.whiteBalance(.kelvin(5600))))
        #expect(!wb.accepts(.whiteBalance(.kelvin(5650))))
        #expect(!wb.accepts(.whiteBalance(.kelvin(12000))))
        #expect(!wb.accepts(.whiteBalance(.preset("daylight"))))

        // Tint is its own setting: a separate key, range and step; unknown until reported.
        let tint = SettingDescriptor(.whiteBalanceTint, domain: SettingDomain(range: -100...100, step: 1))
        #expect(tint.accepts(.whiteBalanceTint(-12)))
        #expect(!tint.accepts(.whiteBalanceTint(0.5)))
        #expect(!tint.accepts(.whiteBalanceTint(150)))
        #expect(!wb.accepts(.whiteBalanceTint(0)))
        #expect(CameraSnapshot(session: CameraSessionID()).value(of: .whiteBalanceTint) == .unknown)

        let zoom = SettingDescriptor(.zoom, domain: SettingDomain(range: 1...4, step: 0.1))
        #expect(zoom.accepts(.zoom(1.5)))
        #expect(!zoom.accepts(.aperture(1.5)))

        // Duration and angle never stand in for each other.
        let angle = SettingDescriptor(.shutter, domain: SettingDomain(choices: [.shutter(.angle(180))]))
        #expect(!angle.accepts(.shutter(.duration(Rational(1, 48)))))
        // Command-only controls have no value domain.
        #expect(!SettingDescriptor(.recording).accepts(.iso(.auto)))
    }

    @Test func provisionalDevicesNeverMerge() {
        let integration = IntegrationID("test.cameras")
        let first = CameraDeviceID.provisional(integration: integration)
        let second = CameraDeviceID.provisional(integration: integration)
        #expect(first != second)
        #expect(first.isProvisional)
        #expect(CameraDeviceID.durable(first.value, integration: integration) != first)
    }

    @Test func receiptsFinishAtTheRightStage() {
        let session = CameraSessionID()
        var readback = CommandReceipt(
            operation: OperationID(), session: session, intent: .startRecording, stage: .accepted)
        #expect(!readback.isFinished)
        readback.stage = .outcomeUnknown
        #expect(readback.isFinished)
        readback.stage = .failed(.superseded)
        #expect(readback.isFinished)
        let acknowledged = CommandReceipt(
            operation: OperationID(), session: session, intent: .focusPoint(x: 0, y: 0),
            stage: .accepted, confirmation: .acknowledgementOnly)
        #expect(acknowledged.isFinished)
    }
}

@Suite struct Entries {
    @Test func everyEntryNeedsARole() throws {
        let session = CameraSessionID()
        try FakeEntries.captureOnly(FakePictureSource(label: "HDMI").descriptor).validate()
        try FakeEntries.controlOnly(session, name: "Wi-Fi").validate()
        try MonitorEntryDescriptor(name: "Viewer", telemetry: .relay, controlAuthority: .readOnly)
            .validate()

        #expect(throws: MonitorEntryError.noRole) {
            try MonitorEntryDescriptor(name: "Empty", controlAuthority: .readOnly).validate()
        }
        #expect(throws: MonitorEntryError.commandAuthorityWithoutSession) {
            try MonitorEntryDescriptor(
                name: "HDMI", picture: FakePictureSource(label: "HDMI").descriptor,
                controlAuthority: .owner
            ).validate()
        }
        #expect(throws: MonitorEntryError.sessionTelemetryWithoutSession) {
            try MonitorEntryDescriptor(
                name: "HDMI", picture: FakePictureSource(label: "HDMI").descriptor,
                telemetry: .cameraSession, controlAuthority: .readOnly
            ).validate()
        }
    }
}

@Suite struct LayoutProjection {
    @Test func projectsWritableSectionsAndCarriesTheRest() async {
        var base = MonitorLayoutCapabilities()
        base.gimbal = true
        base.timecode = true
        #expect(MonitorLayoutCapabilities(CapabilitySnapshot(), base: base) == base)

        let first = await reportedCamera(.djiLike).current.capabilities
        let second = await reportedCamera(.nikonLike).current.capabilities
        let third = await reportedCamera(.lunaLike).current.capabilities
        let a = MonitorLayoutCapabilities(first, base: base)
        #expect(a.zoom && !a.iris && !a.focus && a.gimbal && a.timecode)
        let b = MonitorLayoutCapabilities(second)
        #expect(!b.zoom && b.iris && b.focus && !b.gimbal)
        let c = MonitorLayoutCapabilities(third)
        #expect(c.zoom && !c.iris && c.focus)
    }

    /// Supported observations show, unsupported ones hide, and unknown support keeps the base.
    @Test func projectsObservationSupportAndKeepsTheBaseWhileUnknown() async {
        var base = MonitorLayoutCapabilities()
        base.audio = true
        base.timecode = true
        #expect(MonitorLayoutCapabilities(CapabilitySnapshot(), base: base) == base)
        #expect(MonitorLayoutCapabilities(CapabilitySnapshot()).audio == false)

        let dji = await reportedCamera(.djiLike)
        let video = MonitorLayoutCapabilities(await dji.current.capabilities)
        #expect(video.timecode && video.audio)
        await dji.cameraSwitchesMode(raw: 0x05)
        await dji.cameraReportsStatus()
        let photo = MonitorLayoutCapabilities(await dji.current.capabilities, base: base)
        #expect(!photo.timecode && !photo.audio)

        let luna = MonitorLayoutCapabilities(
            await reportedCamera(.lunaLike).current.capabilities, base: base)
        #expect(luna.timecode && !luna.audio)
    }
}

@Suite struct Feeds {
    @Test func snapshotFeedKeepsOnlyTheLatestAndOutcomesStayReliable() async {
        let camera = await reportedCamera(.djiLike)
        let feed = await camera.snapshots()
        var operations: [OperationID] = []
        for step in 0..<50 {
            operations.append(await camera.submit(.set(.whiteBalance(.kelvin(2000 + 100 * step)))).operation)
            await camera.advance(by: .seconds(1))
        }
        var iterator = feed.makeAsyncIterator()
        let first = await iterator.next()
        let latest = await camera.current
        #expect(first == latest)
        for operation in operations {
            #expect(await camera.outcome(of: operation)?.stage == .confirmed)
        }
    }

    @Test func droppedFeedsAreReleased() async {
        let camera = await reportedCamera(.djiLike)
        let consumer = Task {
            for await _ in await camera.snapshots() {}
        }
        consumer.cancel()
        await consumer.value
        await camera.setAuthority(.owner)
        #expect(await camera.subscriberCount == 0)
        #expect(await camera.currentSnapshot() == camera.current)
    }

    @Test func outcomeWaitsResumeAndCancellationNeverAltersTheOperation() async {
        let camera = await reportedCamera(.lunaLike)
        #expect(await camera.outcome(of: OperationID()) == nil)

        let cancelled = await camera.submit(.set(.iso(.manual(800))))
        let waiter = Task { await camera.outcome(of: cancelled.operation) }
        waiter.cancel()
        #expect(await waiter.value?.stage == .awaitingObservation)
        await camera.advance(by: .seconds(3))
        #expect(await camera.outcome(of: cancelled.operation)?.stage == .confirmed)

        let waited = await camera.submit(.set(.iso(.manual(1600))))
        let patient = Task { await camera.outcome(of: waited.operation) }
        await camera.advance(by: .seconds(3))
        #expect(await patient.value?.stage == .confirmed)

        let pending = await camera.submit(.set(.iso(.manual(3200))))
        #expect(await camera.receipt(of: pending.operation)?.stage == .awaitingObservation)
        #expect(await camera.receipt(of: OperationID()) == nil)
        await camera.advance(by: .seconds(3))
        #expect(await camera.receipt(of: pending.operation)?.stage == .confirmed)

        let interrupted = await camera.submit(.set(.iso(.manual(400))))
        let closing = Task { await camera.outcome(of: interrupted.operation) }
        await camera.close(.requested)
        #expect(await closing.value?.stage == .outcomeUnknown)
    }
}

@Suite struct Portability {
    /// Paths to any reference-type object or raw byte buffer inside a value.
    private func nativeObjects(in value: Any, path: String = "") -> [String] {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .class || value is Data { return [path] }
        return mirror.children.flatMap { nativeObjects(in: $0.value, path: path + "." + ($0.label ?? "_")) }
    }

    @Test func portableStateHoldsNoNativeFrameOrObject() async throws {
        let camera = await reportedCamera(.djiLike)
        let start = await camera.submit(.startRecording)
        await camera.advance(by: .seconds(5))
        await camera.setAuthority(.lease(ControlLease(expiresAt: .zero + .seconds(60))))
        let snapshot = await camera.current
        #expect(!snapshot.settings.isEmpty && snapshot.storage.isKnown)
        let receipt = try #require(await camera.outcome(of: start.operation))
        let entry = MonitorEntryDescriptor(
            name: "A", device: snapshot.device, picture: FakePictureSource(label: "A").descriptor,
            cameraSession: camera.id, telemetry: .cameraSession, controlAuthority: snapshot.authority)
        let command = await camera.command(.set(.zoom(2)))

        for value in [snapshot, receipt, entry, command] as [Any] {
            #expect(nativeObjects(in: value).isEmpty)
        }
        // The detector itself finds objects and byte buffers.
        #expect(nativeObjects(in: (1, NSObject())) == ["..1"])
        #expect(nativeObjects(in: [Data()]) == ["._"])
    }

    @Test func coreImportsOnlyFoundationAndNamesNoManufacturer() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appending(path: "Sources/OpenCineCore")
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        let brands = try Regex(
            #"\b(dji|osmo|nikon|zcine|insta360|insta|luna|pocket|sony|canon|blackmagic|gopro)\b"#
        ).ignoresCase()
        #expect("A Nikon body".firstMatch(of: brands) != nil)
        #expect("one instance".firstMatch(of: brands) == nil)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") where line.hasPrefix("import ") {
                #expect(line == "import Foundation", "\(file.lastPathComponent): \(line)")
            }
            #expect(text.firstMatch(of: brands) == nil, "\(file.lastPathComponent) names a brand")
        }
    }
}

/// Group start/stop planning is MULTI-01's. This shows Core already carries its inputs: one
/// admission rule for eligibility, session identity for deduplication and per-target receipts,
/// for both the strict and the eligible-subset policy.
@Suite struct GroupTargets {
    enum Exclusion: Equatable {
        case noControl
        case rejected(CommandRejection)
    }

    @Test func strictAndEligibleSubsetFromAdmission() async throws {
        let first = await reportedCamera(.djiLike)
        let second = FakeCameraSession.nikonLike()
        await second.cameraReportsStatus()
        let sessions = [first.id: first, second.id: second]
        let capture = FakePictureSource(label: "HDMI").descriptor
        let entries = [
            MonitorEntryDescriptor(
                name: "A", picture: FakePictureSource(label: "A").descriptor,
                cameraSession: first.id, telemetry: .cameraSession, controlAuthority: .owner),
            FakeEntries.controlOnly(first.id, name: "A controls"),
            FakeEntries.controlOnly(second.id, name: "B"),
            FakeEntries.captureOnly(capture),
        ]

        var targets: [CameraSessionID: CameraCommand] = [:]
        var excluded: [String: Exclusion] = [:]
        for entry in entries {
            guard let id = entry.cameraSession, let session = sessions[id] else {
                excluded[entry.name] = .noControl
                continue
            }
            if targets[id] != nil { continue }
            let snapshot = await session.current
            let command = CameraCommand(.startRecording, preconditions: CommandPreconditions(snapshot))
            if let rejection = snapshot.rejection(of: command, at: await session.now) {
                excluded[entry.name] = .rejected(rejection)
            } else {
                targets[id] = command
            }
        }
        #expect(Set(targets.keys) == [first.id])
        #expect(excluded == ["B": .rejected(.unavailable(.notReady)), "HDMI": .noControl])

        let strict = excluded.isEmpty ? targets : [:]
        #expect(strict.isEmpty)

        for (id, command) in targets { _ = await sessions[id]!.submit(command) }
        await first.advance(by: .seconds(5))
        let command = try #require(targets[first.id])
        #expect(await first.outcome(of: command.operation)?.stage == .confirmed)
        #expect(await first.wire == ["record-toggle"])
        #expect(await second.wire.isEmpty)
    }
}
