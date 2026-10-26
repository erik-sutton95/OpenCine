import Foundation
import OpenCineGyro
import Testing

@testable import OpenCineNikon

@MainActor
@Suite struct NikonGyroCameraAdapterTests {
    @Test func framesEmitRecordingOnChangeAndLevelEveryFrame() {
        let adapter = NikonGyroCameraAdapter(write: { _ in true })
        let sink = RecordingSink()
        adapter.attach(sink)

        adapter.receive(frame: frame(recording: false), at: 1)
        adapter.receive(frame: frame(recording: false), at: 2)
        adapter.receive(frame: frame(recording: true), at: 3)

        #expect(sink.events == [
            .recording(false, at: 1), .level(GyroVector3(x: -1, y: 0, z: 0), at: 1),
            .level(GyroVector3(x: -1, y: 0, z: 0), at: 2),
            .recording(true, at: 3), .level(GyroVector3(x: -1, y: 0, z: 0), at: 3),
        ])
    }

    @Test func snapshotsEmitOnlyOnChange() {
        let adapter = NikonGyroCameraAdapter(write: { _ in true })
        let sink = RecordingSink()
        adapter.attach(sink)
        let unread = PTPCameraPropertySnapshot()
        let on = PTPCameraPropertySnapshot(
            vibrationReduction: "ON", electronicVR: "ON", captureSelector: .video)

        adapter.receive(snapshot: unread)
        adapter.receive(snapshot: unread)
        adapter.receive(snapshot: on)
        adapter.receive(snapshot: on)

        #expect(sink.events == [
            .stabilization(nil), .videoMode(nil),
            .stabilization(GyroStabilizationState(
                values: ["movieVR": "ON", "electronicVR": "ON"], lensHasVRSwitch: nil)),
            .videoMode(true),
        ])
    }

    @Test func writeStopsAtFirstRefusal() async throws {
        var received: [[PTPCameraPropertyWrite]] = []
        let adapter = NikonGyroCameraAdapter(write: { writes in
            received.append(writes)
            return false
        })

        let succeeded = await adapter.writeStabilization(["movieVR": "SPORT", "electronicVR": "ON"])
        let movieVR = try #require(PTPCameraPropertyWrite.vibrationReduction(label: "SPORT"))

        #expect(!succeeded)
        #expect(received == [[movieVR, PTPCameraPropertyWrite.electronicVR(on: true)]])
    }

    @Test func partialRestoreFailureShowsNoticeOnce() async throws {
        var writeCalls = 0
        var appliedWrites: [PTPCameraPropertyWrite] = []
        let adapter = NikonGyroCameraAdapter(write: { writes in
            writeCalls += 1
            #expect(writes.count == 2)
            if let first = writes.first { appliedWrites.append(first) }
            return false
        })
        let identity = nativeIdentity(serialNumber: "123", model: "ZR")
        let camera = NikonGyroCamera.identity(identity)
        let pending = GyroPendingRestore(
            cameraID: camera.id, saved: ["movieVR": "SPORT", "electronicVR": "ON"],
            applied: ["movieVR": "OFF", "electronicVR": "OFF"])
        var machine = GyroArmingMachine(pendingRestores: [pending])
        let inputs = GyroArmingInputs(
            toggleOn: false, camera: camera, hostEligible: true, videoMode: true, recording: false,
            stabilization: GyroStabilizationState(
                values: ["movieVR": "OFF", "electronicVR": "OFF"], lensHasVRSwitch: nil),
            settings: adapter.stabilizationSettings, providesLevel: adapter.providesLevel,
            hasSavedCalibration: false)

        let effects = machine.update(inputs)
        #expect(effects == [
            .writeStabilization(["movieVR": "SPORT", "electronicVR": "ON"], purpose: .restore)
        ])
        #expect(await adapter.writeStabilization(["movieVR": "SPORT", "electronicVR": "ON"]) == false)
        let movieVR = try #require(PTPCameraPropertyWrite.vibrationReduction(label: "SPORT"))
        #expect(appliedWrites == [movieVR])
        #expect(machine.writeFinished(.restore, succeeded: false) == [.notice(.restoreFailed)])
        #expect(machine.update(inputs).isEmpty)
        #expect(writeCalls == 1)
    }

    @Test func invalidRequestDoesNotWrite() async {
        var writeCalls = 0
        let adapter = NikonGyroCameraAdapter(write: { _ in
            writeCalls += 1
            return true
        })

        #expect(await adapter.writeStabilization(["movieVR": "invalid", "electronicVR": "ON"]) == false)
        #expect(writeCalls == 0)
    }

    @Test func attachReplaysCurrentState() {
        let adapter = NikonGyroCameraAdapter(write: { _ in true })
        adapter.connected(nativeIdentity(serialNumber: "123", model: "ZR"))
        adapter.receive(frame: frame(recording: true), at: 1)
        adapter.receive(snapshot: PTPCameraPropertySnapshot(
            vibrationReduction: "OFF", electronicVR: "OFF", captureSelector: .video))
        adapter.detach()
        let sink = RecordingSink()

        adapter.attach(sink)

        #expect(sink.events == [
            .connected(NikonGyroCamera.identity(nativeIdentity(serialNumber: "123", model: "ZR"))),
            .recording(true, at: 1),
            .stabilization(GyroStabilizationState(
                values: ["movieVR": "OFF", "electronicVR": "OFF"], lensHasVRSwitch: nil)),
            .videoMode(true),
        ])
    }

    @Test func detachStopsEvents() {
        let adapter = NikonGyroCameraAdapter(write: { _ in true })
        let sink = RecordingSink()
        adapter.attach(sink)
        adapter.connected(nativeIdentity(serialNumber: "123", model: "ZR"))
        let count = sink.events.count

        adapter.detach()
        adapter.connected(nativeIdentity(serialNumber: "123", model: "ZR"))
        adapter.receive(frame: frame(recording: true), at: 4)
        adapter.receive(snapshot: PTPCameraPropertySnapshot(captureSelector: .video))
        adapter.disconnected()

        #expect(sink.events.count == count)
    }

    @Test func attachedSinkCanDeallocate() {
        let adapter = NikonGyroCameraAdapter(write: { _ in true })
        weak var weakSink: RecordingSink?
        var sink: RecordingSink? = RecordingSink()
        weakSink = sink
        if let sink { adapter.attach(sink) }

        sink = nil

        #expect(weakSink == nil)
    }

    private func frame(recording: Bool) -> PTPLiveViewFrame {
        PTPLiveViewFrame(
            jpeg: Data([1]), timecode: Timecode(on: false, hour: 0, minute: 0, second: 0, frame: 0),
            isRecording: recording, level: PTPLevelAngles(roll: 0, pitch: 0, yaw: 0))
    }

    private func nativeIdentity(serialNumber: String, model: String) -> NativeCameraIdentity {
        NativeCameraIdentity(
            host: "192.168.1.2", cameraName: model, manufacturer: "Nikon", model: model,
            deviceVersion: "1.0", serialNumber: serialNumber, establishmentSummary: "SIMULATED")
    }
}

@MainActor
private final class RecordingSink: GyroCameraSink {
    var events: [GyroCameraEvent] = []

    func receive(_ event: GyroCameraEvent) {
        events.append(event)
    }
}
