import Foundation
import OpenCineCore
import OpenCineMedia
import Testing

@testable import OpenCineNikon

/// CORE-02: the Nikon slice behind `OpenCineCore.CameraSession`. The driver stands in for the
/// app model's write queue and safe point; the hooks are called exactly where the model calls them.
@MainActor
@Suite("Nikon camera session seam")
struct NikonCameraSessionTests {

    @MainActor
    final class Driver: NikonControlDriver {
        var nikonControlFacts: NikonControlFacts
        /// What reached the write queue: setting, label and the encoder's writes.
        var queued:
            [(setting: NikonControlSetting, label: String, writes: [PTPCameraPropertyWrite])] =
                []
        var records: [Bool] = []
        /// Simulates an adapter that advertises a value the encoder cannot express.
        var encoderBroken = false

        init(_ facts: NikonControlFacts) { nikonControlFacts = facts }

        func queueSettingWrites(
            _ label: String, for setting: NikonControlSetting, operation: OperationID?
        ) -> Int {
            // The same encoder the model's queue uses.
            let writes =
                encoderBroken
                ? []
                : PTPCameraPropertyWrite.requests(
                    control: setting.cameraControl, label: label,
                    snapshot: nikonControlFacts.reported)
            if !writes.isEmpty { queued.append((setting, label, writes)) }
            return writes.count
        }

        func queueRecord(start: Bool, operation: OperationID) { records.append(start) }
    }

    /// A ZR in movie mode, exposure M, H.265, idle, with its own live view running.
    static func movieFacts(codec: String = "H.265 10-bit MOV") -> NikonControlFacts {
        NikonControlFacts(
            liveViewReady: true,
            reported: PTPCameraPropertySnapshot(
                iso: 800, isoAuto: false, exposureMode: "M", wbMode: "Auto", wbKelvin: 5560,
                fileType: codec, batteryPercent: 80, captureSelector: .video),
            recording: false,
            whiteBalancePresets: ["Auto", "Natural auto", "Sunny", "Cloudy", "0x8099"])
    }

    /// Z app getters (multicam slots, media source identity) call `refresh()` from view code.
    /// Unchanged camera facts reuse the published snapshot; changed facts map it once.
    @Test func refreshWithUnchangedFactsReusesTheSnapshot() {
        let driver = Driver(Self.movieFacts())
        let session = NikonCameraSession(driver: driver, serialNumber: "3000123")
        let first = session.refresh()
        for _ in 0..<50 { _ = session.refresh() }
        #expect(session.snapshotBuilds == 1)
        #expect(session.refresh() == first)

        driver.nikonControlFacts.reported = PTPCameraPropertySnapshot(
            iso: 1600, isoAuto: false, exposureMode: "M", wbMode: "Auto", wbKelvin: 5560,
            fileType: "H.265 10-bit MOV", batteryPercent: 80, captureSelector: .video)
        #expect(session.refresh().settings[.iso]?.value == .iso(.manual(1600)))
        _ = session.refresh()
        #expect(session.snapshotBuilds == 2)
        driver.nikonControlFacts.holdsControl = false
        #expect(session.refresh().authority == .unavailable(.authority))
        #expect(session.snapshotBuilds == 3)
    }

    @Test func recordingFactsUseReportedDimensionsAndNeverPreviewCodec() {
        var facts = Self.movieFacts()
        facts.reported = PTPCameraPropertySnapshot(exposureMode: "S", resolution: "6048x3402", fps: 25,
            fileType: "R3D NE 12-bit R3D", captureSelector: .video)
        let driver = Driver(facts)
        let at = MonotonicInstant(.seconds(42))
        let session = NikonCameraSession(driver: driver, serialNumber: "3000123", now: { at })
        let snapshot = session.refresh()
        #expect(snapshot.exposureProgram.value == .shutterPriority)
        #expect(snapshot.recordingFormat.dimensions.value == CameraRecordingFormat.Dimensions(width: 6048, height: 3402))
        #expect(snapshot.recordingFormat.dimensions.origin == .cameraReported)
        #expect(snapshot.recordingFormat.dimensions.observedAt == at)
        #expect(snapshot.recordingFormat.codec.value == "R3D NE 12-bit R3D")
        #expect(snapshot.recordingFormat.profile.value == "Log3G10")
        #expect(snapshot.recordingFormat.profile.origin == .protocolDerived)
        driver.nikonControlFacts.reported = PTPCameraPropertySnapshot(resolution: "0x3402", fps: 0,
            fileType: "H.265 10-bit MOV", captureSelector: .video)
        let unknown = session.refresh()
        #expect(unknown.recordingFormat.dimensions.value == nil)
        #expect(unknown.recordingFormat.profile.value == nil, "A selectable codec does not establish tone")
        #expect(unknown.recordingFormat.codec.value == "H.265 10-bit MOV")
        #expect(driver.queued.isEmpty && driver.records.isEmpty)
    }

    /// MULTI-03 F1: observations are stamped on the injected (by default the shared) host clock,
    /// not on a reference private to this session.
    @Test func observationsUseTheSharedClock() {
        let driver = Driver(Self.movieFacts())
        let at = MonotonicInstant(.seconds(42))
        let session = NikonCameraSession(driver: driver, serialNumber: "3000123", now: { at })
        #expect(session.refresh().recording.observedAt == at)
        let shared = NikonCameraSession(driver: driver, serialNumber: "3000123")
        let stamped = shared.refresh().recording.observedAt
        #expect(stamped.map { MonotonicInstant.now() - $0 < .seconds(1) } == true)
    }

    /// Hardware pass 3.4: the shared storage cycle reads the Nikon session's storage as every
    /// app does (free space, percentage, then the estimated time; photo without the time).
    @Test func storageReadsTheSharedStorageCycle() {
        var facts = Self.movieFacts(codec: "R3D NE 12-bit R3D")
        facts.reported = PTPCameraPropertySnapshot(
            resolution: "6048x3402", fps: 25, fileType: "R3D NE 12-bit R3D", captureSelector: .video)
        facts.storage = PTPStorageInfo(totalCapacityBytes: 1_000_000_000_000, freeSpaceBytes: 470_000_000_000)
        let session = NikonCameraSession(driver: Driver(facts), serialNumber: "3000123")
        let storage = session.refresh().storage
        #expect(StorageReadoutCycle.forms(storage, photo: false) == ["470GB", "47%", "~40 Min"])
        #expect(StorageReadoutCycle.forms(storage, photo: true) == ["470GB", "47%"])
    }

    @Test func storageEstimateRequiresKnownFormatAndRetainsZeroAndOrigin() throws {
        let at = MonotonicInstant(.seconds(42))
        var facts = Self.movieFacts(codec: "R3D NE 12-bit R3D")
        facts.reported = PTPCameraPropertySnapshot(
            resolution: "6048x3402", fps: 25, fileType: "R3D NE 12-bit R3D", captureSelector: .video)
        facts.storage = PTPStorageInfo(totalCapacityBytes: 1_000_000_000_000, freeSpaceBytes: 470_000_000_000)
        let driver = Driver(facts)
        let session = NikonCameraSession(driver: driver, serialNumber: "3000123", now: { at })
        let volume = try #require(session.refresh().storage.value?.first)
        #expect(volume.remainingRecordingTime.value == .seconds(40 * 60))
        #expect(volume.remainingRecordingTime.origin == .estimated)
        #expect(volume.remainingRecordingTime.observedAt == at)
        for (codec, resolution, fps) in [
            ("Mystery Codec", "6048x3402", 25), ("R3D NE 12-bit R3D", "-1x-1", 25),
            ("R3D NE 12-bit R3D", "6048x3402", 0), ("R3D NE 12-bit R3D", "6048xgarbage", 25)
        ] {
            driver.nikonControlFacts.reported = PTPCameraPropertySnapshot(
                resolution: resolution, fps: fps, fileType: codec, captureSelector: .video)
            #expect(session.refresh().storage.value?.first?.remainingRecordingTime.value == nil)
        }
        driver.nikonControlFacts.reported = facts.reported
        driver.nikonControlFacts.storage = PTPStorageInfo(totalCapacityBytes: 0, freeSpaceBytes: 470_000_000_000)
        #expect(session.refresh().storage.value?.first?.remainingRecordingTime.value == .seconds(40 * 60))
        driver.nikonControlFacts.storage = PTPStorageInfo(totalCapacityBytes: 1_000_000_000_000, freeSpaceBytes: 0)
        #expect(session.refresh().storage.value?.first?.remainingRecordingTime.value == .zero)
        driver.nikonControlFacts.storage = nil
        #expect(session.refresh().storage.value == nil)
    }

    /// A5-04: the header timecode reaches the common snapshot with its frame field, declared at
    /// the body's movie rate; an off header is unknown, never a frozen 00:00:00:00.
    @Test("Header timecode publishes with frames at the reported movie rate")
    func headerTimecodePublishesFrames() {
        var facts = Self.movieFacts()
        facts.reported = PTPCameraPropertySnapshot(
            iso: 800, isoAuto: false, exposureMode: "M", fps: 25, fileType: "H.265 10-bit MOV",
            captureSelector: .video)
        facts.timecode = Timecode(on: true, hour: 1, minute: 2, second: 3, frame: 17).running
        let driver = Driver(facts)
        let session = NikonCameraSession(driver: driver, serialNumber: "3000123")
        let snapshot = session.refresh()
        #expect(snapshot.timecode.value == CameraTimecode(hours: 1, minutes: 2, seconds: 3, frames: 17))
        #expect(snapshot.capabilities.timecodeCapability == .supported(.frames(rate: Rational(25), dropFrame: nil)))
        driver.nikonControlFacts.timecode = Timecode(on: false, hour: 1, minute: 2, second: 3, frame: 18).running
        #expect(session.refresh().timecode == .unknown)
    }

    /// A5-09: the movie rate is a typed read-only Rational, the same one the timecode counts at.
    @Test("The movie rate publishes as a read-only Rational")
    func movieRatePublishesAsAReadOnlyRational() {
        var facts = Self.movieFacts()
        facts.reported = PTPCameraPropertySnapshot(
            iso: 800, isoAuto: false, exposureMode: "M", fps: 25, fileType: "H.265 10-bit MOV",
            captureSelector: .video)
        let driver = Driver(facts)
        let session = NikonCameraSession(driver: driver, serialNumber: "3000123")
        let snapshot = session.refresh()
        #expect(snapshot.value(of: .frameRate).value == .frameRate(Rational(25)))
        #expect(snapshot.capabilities[.frameRate]?.access == .readOnly)
        #expect(session.request(.set(.frameRate(Rational(24)))).stage == .rejected(.readOnly))
        #expect(driver.queued.isEmpty)
        driver.nikonControlFacts.reported = PTPCameraPropertySnapshot(
            iso: 800, isoAuto: false, exposureMode: "M", fps: 0, fileType: "H.265 10-bit MOV",
            captureSelector: .video)
        #expect(session.refresh().value(of: .frameRate).value == nil, "no rate is unknown")
    }

    /// A5-01: BatteryLevel is a five-step gauge, so the common reading declares fifths, not percent.
    @Test("The camera battery is declared at the body's five-step precision")
    func batteryDeclaresFiveSteps() {
        let session = NikonCameraSession(driver: Driver(Self.movieFacts()), serialNumber: "3000123")
        let battery = session.refresh().power.battery
        #expect(battery.value == 0.8)
        #expect(battery.precision == .quantized(step: 0.2))
        #expect(NikonCameraSession.batteryFraction(58) == 0.6)
        #expect(NikonCameraSession.batteryFraction(1) == 0.2)
        #expect(NikonCameraSession.batteryFraction(0) == nil)
    }

    @Test("Every advertised writable value reaches the write queue; none is silently unsupported")
    func advertisedValuesAreImplemented() {
        var photo = Self.movieFacts()
        photo.reported = photo.reported.applying(property: .liveViewSelector, data: Data([0]))
        for facts in [Self.movieFacts(), Self.movieFacts(codec: "R3D NE 12-bit R3D"), photo] {
            let driver = Driver(facts)
            let session = NikonCameraSession(driver: driver, serialNumber: "3000123")
            let snapshot = session.refresh()
            for descriptor in snapshot.capabilities.descriptors.values
            where descriptor.access == .readWrite && descriptor.availability == .available {
                guard let domain = descriptor.domain else {
                    #expect(descriptor.key == .recording)
                    #expect(session.request(.startRecording).stage == .admitted)
                    #expect(driver.records == [true])
                    continue
                }
                var values = domain.choices
                if let range = domain.range {
                    values += [range.lowerBound, range.upperBound].map {
                        .whiteBalance(.kelvin(Int($0)))
                    }
                }
                #expect(!values.isEmpty, "\(descriptor.key) advertises an empty domain")
                for value in values {
                    let before = driver.queued.count
                    let receipt = session.request(.set(value))
                    #expect(receipt.stage == .admitted, "\(value) was not admitted")
                    #expect(driver.queued.count == before + 1, "\(value) never reached the queue")
                }
            }
        }
        // The hex preset the decoder cannot name is never advertised.
        let unnamed = Driver(Self.movieFacts())
        let snapshot = NikonCameraSession(driver: unnamed, serialNumber: "").refresh()
        #expect(
            snapshot.capabilities[.whiteBalance]?.accepts(.whiteBalance(.preset("0x8099"))) == false
        )
        #expect(snapshot.device?.isProvisional == true)

        // An advertised value the encoder cannot express never reports progress.
        let broken = Driver(Self.movieFacts())
        broken.encoderBroken = true
        let session = NikonCameraSession(driver: broken, serialNumber: "")
        #expect(session.request(.set(.iso(.manual(1600)))).stage == .failed(.notSent))
    }

    @Test("Readback decides: match confirms, mismatch is not applied, a failed read is unknown")
    func readbackDecidesTheOutcome() {
        let driver = Driver(Self.movieFacts())
        let session = NikonCameraSession(driver: driver, serialNumber: "3000123")

        // Kelvin is two writes (colour-temperature mode, then the temperature): both must read back.
        let kelvin = session.request(.set(.whiteBalance(.kelvin(4000)))).operation
        let writes = driver.queued.last!.writes
        #expect(writes.count == 2)
        session.operationSent(kelvin)
        session.writeLanded(kelvin, write: writes[0], readback: writes[0].data)
        #expect(stage(session, kelvin) == .accepted)
        session.writeLanded(kelvin, write: writes[1], readback: writes[1].data)
        #expect(stage(session, kelvin) == .confirmed)

        // The camera took the ISO write but reports a different value (clamped or refused in part).
        let iso = session.request(.set(.iso(.manual(1600)))).operation
        let isoWrite = driver.queued.last!.writes.last!
        session.operationSent(iso)
        let other = PTPCameraPropertyWrite.isoWrite(label: "1250", dualBase: false)!
        session.writeLanded(iso, write: isoWrite, readback: other.data)
        #expect(stage(session, iso) == .failed(.notApplied))

        // The read after the write failed: the value may have landed, so never success.
        let unread = session.request(.set(.iso(.manual(3200)))).operation
        session.operationSent(unread)
        session.writeLanded(unread, write: driver.queued.last!.writes.last!, readback: nil)
        #expect(stage(session, unread) == .outcomeUnknown)

        // A PTP refusal is a rejection; a lost transaction is unknown.
        let refused = session.request(.set(.whiteBalance(.preset("Sunny")))).operation
        session.operationSent(refused)
        session.commandFailed(refused, cameraRefused: true)
        #expect(stage(session, refused) == .rejected(.cameraRefused))
        let lost = session.request(.set(.whiteBalance(.auto))).operation
        session.operationSent(lost)
        session.commandFailed(lost, cameraRefused: false)
        #expect(stage(session, lost) == .outcomeUnknown)
    }

    @Test("Camera observations exclude queued targets, including after command confirmation")
    func controlTargetsAreNotCameraReports() {
        let driver = Driver(Self.movieFacts())
        let session = NikonCameraSession(driver: driver, serialNumber: "3000123")
        let operation = session.request(.set(.iso(.manual(1600)))).operation
        #expect(session.refresh().value(of: .iso).value == .iso(.manual(800)))
        session.operationSent(operation)
        #expect(session.refresh().value(of: .iso).value == .iso(.manual(800)))
        guard let write = driver.queued.last?.writes.last else {
            Issue.record("The admitted ISO target never reached the wire queue")
            return
        }
        session.writeLanded(operation, write: write, readback: write.data)
        #expect(stage(session, operation) == .confirmed)
        #expect(session.refresh().value(of: .iso).value == .iso(.manual(800)))

        driver.nikonControlFacts.reported = driver.nikonControlFacts.reported.applying(
            property: .isoControlSensitivity, data: Data(ByteCoding.uint32LE(1250)))
        #expect(session.refresh().value(of: .iso).value == .iso(.manual(1250)))
    }

    @Test("Common movie exposure uses the active circuit and exact advertised domain")
    func movieExposureDomainsAndReadback() {
        var facts = Self.movieFacts()
        facts.reported = facts.reported.applying(
            property: .movieShutterMode,
            data: Data([PTPCameraPropertyDecoders.shutterModeCode(.speed)])
        )
        .applying(property: .movieShutterSpeed, data: Data(ByteCoding.uint32LE(2 << 16 | 100)))
        .applying(property: .movieFNumber, data: Data(ByteCoding.uint16LE(280)))
        facts.shutterLabels = ["2/100", "1/100", "180°", "1/0", "Bulb"]
        facts.apertureLabels = ["f/2.8", "f/4.0", "f/NaN", "unknown"]
        let driver = Driver(facts)
        let session = NikonCameraSession(driver: driver, serialNumber: "3000123")
        #expect(session.refresh().value(of: .shutter).value == .shutter(.duration(Rational(1, 50))))
        #expect(session.refresh().value(of: .aperture).value == .aperture(2.8))
        #expect(session.request(.set(.shutter(.angle(180)))).stage == .rejected(.outOfDomain))
        #expect(session.request(.set(.aperture(5.6))).stage == .rejected(.outOfDomain))
        #expect(driver.queued.isEmpty)

        let shutter = session.request(.set(.shutter(.duration(Rational(1, 100))))).operation
        let aperture = session.request(.set(.aperture(4))).operation
        #expect(driver.queued.map(\.setting) == [.shutter, .aperture])
        #expect(
            driver.queued.flatMap(\.writes).map(\.property) == [.movieShutterSpeed, .movieFNumber])
        for (operation, item) in zip([shutter, aperture], driver.queued) {
            guard let write = item.writes.first else {
                Issue.record("An advertised exposure value never reached the existing encoder")
                return
            }
            session.operationSent(operation)
            session.writeLanded(operation, write: write, readback: write.data)
            #expect(stage(session, operation) == .confirmed)
        }
        // Confirmation did not manufacture a new camera observation.
        #expect(session.refresh().value(of: .aperture).value == .aperture(2.8))
    }

    @Test("A reported exposure with no write domain stays visible and unavailable")
    func reportDoesNotCreateAWriteDomain() {
        var facts = Self.movieFacts()
        facts.reported = facts.reported
            .applying(
                property: .movieShutterMode,
                data: Data([PTPCameraPropertyDecoders.shutterModeCode(.speed)])
            )
            .applying(property: .movieShutterSpeed, data: Data(ByteCoding.uint32LE(1 << 16 | 50)))
            .applying(property: .movieFNumber, data: Data(ByteCoding.uint16LE(280)))
        let driver = Driver(facts)
        let session = NikonCameraSession(driver: driver, serialNumber: "")
        #expect(session.refresh().value(of: .shutter).value == .shutter(.duration(Rational(1, 50))))
        #expect(session.refresh().value(of: .aperture).value == .aperture(2.8))
        #expect(
            session.request(.set(.shutter(.duration(Rational(1, 50))))).stage
                == .rejected(.unavailable(.notReady)))
        #expect(session.request(.set(.aperture(2.8))).stage == .rejected(.unavailable(.notReady)))
        #expect(driver.queued.isEmpty)
    }

    @Test("Mode changes retire exposure edits; locked and unknown circuits cannot write")
    func exposureModeAndLockAdmission() {
        var facts = Self.movieFacts()
        facts.reported = facts.reported.applying(
            property: .movieShutterMode,
            data: Data([PTPCameraPropertyDecoders.shutterModeCode(.speed)])
        )
        .applying(property: .movieShutterSpeed, data: Data(ByteCoding.uint32LE(1 << 16 | 50)))
        facts.shutterLabels = ["1/50", "1/100", "180°"]
        let driver = Driver(facts)
        let session = NikonCameraSession(driver: driver, serialNumber: "3000123")
        let stale = CameraCommand(
            .set(.shutter(.duration(Rational(1, 100)))),
            preconditions: CommandPreconditions(session.refresh()))
        driver.nikonControlFacts.reported = driver.nikonControlFacts.reported.applying(
            property: .movieShutterMode,
            data: Data([PTPCameraPropertyDecoders.shutterModeCode(.angle)])
        )
        .applying(property: .movieShutterAngle, data: Data(ByteCoding.int32LE(18_000)))
        #expect(session.submit(stale).stage == .rejected(.staleCapabilities))
        driver.nikonControlFacts.reported = driver.nikonControlFacts.reported.applying(
            property: .movieTVLockSetting, data: Data([1]))
        #expect(
            session.request(.set(.shutter(.angle(180)))).stage == .rejected(.unavailable(.busy)))
        driver.nikonControlFacts.reported = driver.nikonControlFacts.reported.applying(
            property: .liveViewSelector, data: Data([0]))
        #expect(session.refresh().value(of: .shutter).value == nil)
        #expect(session.request(.set(.shutter(.angle(180)))).stage == .rejected(.supportUnknown))
        #expect(driver.queued.isEmpty)

        // An unreported mode is not a lock: the label shape picks the circuit (baseline Z).
        let unknown = PTPCameraPropertySnapshot(shutterSpeed: "1/50", captureSelector: .video)
        #expect(
            (NikonExposureSettings.reported(unknown)[.shutter] ?? nil)
                == .shutter(.duration(Rational(1, 50))))
        #expect(
            NikonExposureSettings.descriptors(unknown, shutterLabels: ["1/50"], apertureLabels: [])
                .map(\.availability) == [.available])
        // No reported shutter value at all: still unknown, nothing to write.
        #expect(
            NikonExposureSettings.descriptors(
                PTPCameraPropertySnapshot(captureSelector: .video), shutterLabels: [], apertureLabels: []
            ).isEmpty)
    }

    @Test("A body that never reports its shutter mode reads and writes movie SHUTTER by label shape")
    func unknownShutterModeWritesByLabelShape() {
        // Z6III-class bodies have no MovieShutterMode; the baseline encoder wrote by label shape.
        var facts = Self.movieFacts()
        facts.reported = facts.reported.applying(
            property: .movieShutterSpeed, data: Data(ByteCoding.uint32LE(1 << 16 | 50)))
        let driver = Driver(facts)
        let session = NikonCameraSession(driver: driver, serialNumber: "3000123")
        #expect(session.refresh().value(of: .shutter).value == .shutter(.duration(Rational(1, 50))))
        #expect(session.refresh().capabilities[.shutter]?.availability == .available)
        _ = session.request(.set(.shutter(.duration(Rational(1, 100)))))
        // The body reports no angle, so the angle circuit is not offered.
        #expect(session.request(.set(.shutter(.angle(180)))).stage == .rejected(.outOfDomain))
        #expect(driver.queued.flatMap(\.writes).map(\.property) == [.movieShutterSpeed])

        // Advertised labels of a reported circuit are the domain while the mode is unknown.
        driver.nikonControlFacts.shutterLabels = ["1/50", "1/100"]
        #expect(
            session.request(.set(.shutter(.duration(Rational(1, 200))))).stage
                == .rejected(.outOfDomain))
        // A camera lock still wins.
        driver.nikonControlFacts.reported = driver.nikonControlFacts.reported.applying(
            property: .movieTVLockSetting, data: Data([1]))
        #expect(
            session.request(.set(.shutter(.duration(Rational(1, 100))))).stage
                == .rejected(.unavailable(.busy)))
    }

    @Test("The confirmed record target runs; a target the camera already reports sends nothing")
    func confirmedRecordTargetIsHonored() {
        // Seam: the prompt asked to start, the camera started on its own meanwhile.
        var facts = Self.movieFacts()
        facts.recording = true
        let driver = Driver(facts)
        let session = NikonCameraSession(driver: driver, serialNumber: "3000123")
        #expect(session.request(.startRecording).stage == .confirmed)
        #expect(driver.records.isEmpty, "a satisfied start must not reach the camera")

        // A stop pressed while a start is still queued must replace it, not be skipped because
        // the camera has not started yet (the app-level regression is in RelayRecordControlTests).
        driver.nikonControlFacts.recording = false
        #expect(session.request(.startRecording).stage == .admitted)
        #expect(session.request(.stopRecording).stage == .admitted)
        #expect(driver.records == [true, false])
    }

    @Test("Leaving Auto ISO can write back the off-ladder value the camera parked on")
    func autoParkedISOIsWritable() {
        var facts = Self.movieFacts()
        facts.reported = facts.reported.applying(
            property: .isoControlSensitivity, data: Data(ByteCoding.uint32LE(51_200)))
        let driver = Driver(facts)
        let session = NikonCameraSession(driver: driver, serialNumber: "3000123")
        #expect(session.request(.set(.iso(.manual(51_200)))).stage == .admitted)
        #expect(session.request(.set(.iso(.manual(40_000)))).stage == .rejected(.outOfDomain))
    }

    @Test("Settings need no picture; record keeps its live-view preflight")
    func commandsWithoutPicture() {
        var facts = Self.movieFacts()
        facts.liveViewReady = false
        let driver = Driver(facts)
        let session = NikonCameraSession(driver: driver, serialNumber: "3000123")
        #expect(session.request(.set(.iso(.manual(400)))).stage == .admitted)
        #expect(session.request(.set(.whiteBalance(.kelvin(3200)))).stage == .admitted)
        #expect(driver.queued.count == 2)
        #expect(session.request(.startRecording).stage == .rejected(.unavailable(.notReady)))
        #expect(driver.records.isEmpty)
    }

    /// VENDOR-02 gate: the displayed source changing (HDMI, relay) or no picture at all must not
    /// stop admissible commands. Settings run through the control pump to camera readback and
    /// status keeps arriving; record stays gated by its own live-view preflight, per operation.
    @Test("No picture source: admissible settings reach readback and status flows; record gated")
    func admissibleCommandsServiceableWithNoPicture() {
        var facts = Self.movieFacts()
        facts.liveViewReady = false
        let driver = Driver(facts)
        let session = NikonCameraSession(driver: driver, serialNumber: "3000123")

        for value: SettingValue in [.iso(.manual(400)), .whiteBalance(.kelvin(3200))] {
            let operation = session.request(.set(value)).operation
            session.operationSent(operation)
            for write in driver.queued.last!.writes {
                session.writeLanded(operation, write: write, readback: write.data)
            }
            #expect(stage(session, operation) == .confirmed, "\(value) did not complete")
        }

        // Camera-reported status still updates the snapshot with nothing presented.
        driver.nikonControlFacts.reported = driver.nikonControlFacts.reported.applying(
            property: .isoControlSensitivity, data: Data(ByteCoding.uint32LE(400)))
        #expect(session.refresh().value(of: .iso).value == .iso(.manual(400)))

        // Record keeps its explicit live-view requirement and sends nothing.
        #expect(session.request(.startRecording).stage == .rejected(.unavailable(.notReady)))
        #expect(driver.records.isEmpty)
        #expect(session.refresh().capabilities[.recording]?.availability == .unavailable(.notReady))
    }

    @Test("An accepted record waits for the camera's report, and times out without it")
    func recordWaitsForObservation() async {
        let driver = Driver(Self.movieFacts())
        let session = NikonCameraSession(
            driver: driver, serialNumber: "3000123", recordObservationTimeout: .milliseconds(20))
        let start = session.request(.startRecording).operation
        session.operationSent(start)
        session.recordAccepted(start)
        #expect(stage(session, start) == .awaitingObservation)
        driver.nikonControlFacts.recording = true
        session.refresh()
        #expect(stage(session, start) == .confirmed)
        #expect(session.refresh().recording.value == .recording)

        let stop = session.request(.stopRecording).operation
        session.operationSent(stop)
        session.recordAccepted(stop)
        let outcome = await session.outcome(of: stop)
        #expect(outcome?.stage == .timedOut)
        #expect(session.refresh().recording.value == .recording, "a timeout invents no state")
    }

    @Test("Dropped, closed and unknown stay honest")
    func droppedClosedAndUnknown() async {
        let driver = Driver(NikonControlFacts())
        let blank = NikonCameraSession(driver: driver, serialNumber: "")
        let unknown = blank.refresh()
        #expect(!unknown.recording.isKnown)
        #expect(!unknown.power.battery.isKnown)
        #expect(unknown.settings.isEmpty)
        #expect(unknown.capabilities[.iso]?.availability == .unavailable(.mode))

        // The session holds its driver weakly (the model owns the session), so keep it alive.
        let movie = Driver(Self.movieFacts())
        let session = NikonCameraSession(driver: movie, serialNumber: "1")
        let coalesced = session.request(.set(.iso(.manual(500)))).operation
        session.operationDropped(coalesced, superseded: true)
        #expect(stage(session, coalesced) == .failed(.superseded))
        let reset = session.request(.set(.iso(.manual(500)))).operation
        session.operationDropped(reset)
        #expect(stage(session, reset) == .failed(.notSent))

        let inFlight = session.request(.set(.iso(.manual(640)))).operation
        session.operationSent(inFlight)
        let queued = session.request(.set(.whiteBalance(.preset("Cloudy")))).operation
        var feed = session.snapshots().makeAsyncIterator()
        _ = await feed.next()
        session.close(.linkLost)
        #expect(stage(session, inFlight) == .outcomeUnknown)
        #expect(stage(session, queued) == .failed(.notSent))
        #expect(await feed.next()?.connection == .disconnected(.linkLost))
        #expect(await feed.next() == nil)
        #expect(session.request(.set(.iso(.manual(800)))).stage == .rejected(.sessionClosed))
    }

    private func stage(_ session: NikonCameraSession, _ operation: OperationID) -> CommandStage? {
        session.receipt(of: operation)?.stage
    }
}
