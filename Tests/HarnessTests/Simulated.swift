// SIMULATED. Every camera in this harness is a faithful fixture behind the integration's real
// port: the real `DJICameraSessionAdapter`, `NikonCameraSession` and `LunaCameraSession` run, and
// only the app-side link below them is scripted. Nothing here touches hardware or claims to.

import Foundation
import HarnessComposition
import HarnessEngine
import Insta360Apple
import Insta360AppleTestSupport
import OpenCineCore
import OpenCineCoreTestSupport
import OpenCineDJI
import OpenCineMulticam
import OpenCineNikon

/// How a simulated camera answers a record command.
enum RecordAnswer {
    /// Accepts, then reports the requested state.
    case confirm
    /// Refuses on the wire (DJI NACK, Nikon PTP refusal).
    case refuse
    /// Accepts but never reports the new state.
    case neverReports
}

/// SIMULATED DJI app session behind `DJIControlPort`: a linked Pocket in video mode, idle,
/// reporting ISO 100 and Auto white balance. Answers synchronously, as a loopback link would.
@MainActor
final class SimulatedDJIPort: DJIControlPort {
    var status: CameraStatus = {
        var status = CameraStatus()
        status.shootingMode = 1
        status.recordingReported = true
        status.isoIndex = .iso100
        status.whiteBalance = .auto(tint: 0)
        status.batteryPercent = 80
        return status
    }()
    var whiteBalanceDisplayStatus: CameraStatus { status }
    var currentShootingMode: ShootingMode? { ShootingMode.fromStatus(status.shootingMode) }
    var connectedCameraID: String?
    var connectedModel: CameraModel? = CameraModel.resolve(modelId: 0x0020, name: "Osmo Pocket 3")
    var admitsMultiviewControl = true
    var isBusy = false
    var link = DJILinkState.ready
    var controlNote: String?

    var recordAnswer = RecordAnswer.confirm
    /// The app session tells its adapter about status changes; so does this port.
    weak var adapter: DJICameraSessionAdapter?
    private(set) var fired: [String] = []

    init(serial: String) { connectedCameraID = serial }

    func takePhoto() { fired.append("photo") }

    func setISO(_ index: IsoIndex, onStage: (@MainActor (ControlWireEvent) -> Void)?) {
        fired.append("iso \(index.rawValue)")
        onStage?(.sent)
        onStage?(.acknowledged)
        status.isoIndex = index
        adapter?.sessionDidChange()
    }

    func setRecording(_ start: Bool, onStage: (@MainActor (ControlWireEvent) -> Void)?) {
        fired.append("record \(start)")
        onStage?(.sent)
        switch recordAnswer {
        case .confirm:
            onStage?(.acknowledged)
            status.isRecording = start
            adapter?.sessionDidChange()
        case .refuse:
            onStage?(.refused)
        case .neverReports:
            onStage?(.acknowledged)
        }
    }

    func setWhiteBalanceAuto(tint: Int?, onStage: (@MainActor (ControlWireEvent) -> Void)?) {
        fired.append("wb auto \(tint ?? 0)")
    }

    func setWhiteBalanceCustom(
        kelvin: Int, tint: Int, onStage: (@MainActor (ControlWireEvent) -> Void)?
    ) {
        fired.append("wb \(kelvin) \(tint)")
    }
}

/// SIMULATED Nikon control service behind `NikonControlDriver`: a Z body in movie mode with its
/// own live view running, idle, ISO 400, Auto white balance. Its safe point runs synchronously.
@MainActor
final class SimulatedNikonDriver: NikonControlDriver {
    var nikonControlFacts = NikonControlFacts(
        holdsControl: true, liveViewReady: true,
        reported: PTPCameraPropertySnapshot(
            iso: 400, isoAuto: false, exposureMode: "M", wbMode: "Auto", fileType: "H.265 10-bit",
            batteryPercent: 90, captureSelector: .video),
        recording: false, whiteBalancePresets: ["Auto", "Natural light auto", "Cloudy"])

    var recordAnswer = RecordAnswer.confirm
    weak var session: NikonCameraSession?
    private(set) var queued: [String] = []

    func queueSettingWrites(
        _ label: String, for setting: NikonControlSetting, operation: OperationID?
    ) -> Int {
        queued.append("\(setting) \(label)")
        return 1
    }

    func queueRecord(start: Bool, operation: OperationID) {
        queued.append("record \(start)")
        guard let session else { return }
        session.operationSent(operation)
        switch recordAnswer {
        case .confirm:
            session.recordAccepted(operation)
            nikonControlFacts.recording = start
            session.refresh()
        case .refuse:
            session.commandFailed(operation, cameraRefused: true)
        case .neverReports:
            session.recordAccepted(operation)
        }
    }
}

/// One SIMULATED camera of each integration plus a capture-only HDMI picture, composed through
/// the composition root in one process.
@MainActor
struct Rig {
    let djiPort = SimulatedDJIPort(serial: "SIM-POCKET-1")
    let dji: DJICameraSessionAdapter
    let nikonDriver = SimulatedNikonDriver()
    let nikon: NikonCameraSession
    let lunaCamera = FakeLuna()
    let luna: LunaCameraSession
    let hdmi = FakePictureSource(label: "HDMI").descriptor

    /// Short timeouts so failure scenarios finish quickly; success never waits for them.
    init(timeout: Duration = .milliseconds(300),
        now: @escaping @Sendable () -> MonotonicInstant = MonotonicInstant.now) {
        dji = Composition.djiSession(over: djiPort)
        dji.wireTimeout = timeout
        dji.readbackTimeout = timeout
        djiPort.adapter = dji
        nikon = Composition.nikonSession(
            over: nikonDriver, serialNumber: "SIM-Z-1", recordObservationTimeout: timeout, now: now)
        nikonDriver.session = nikon
        luna = lunaCamera.connectedSession(settle: timeout, now: now)
    }

    var sessions: [any CameraSession] { [dji, nikon, luna] }
    var map: [CameraSessionID: any CameraSession] { sessionMap(sessions) }

    func entry(
        _ name: String, _ session: any CameraSession, picture: Bool = true,
        authority: ControlAuthority = .owner
    ) -> MonitorEntryDescriptor {
        MonitorEntryDescriptor(
            name: name, picture: picture ? PictureSourceDescriptor(label: name) : nil,
            cameraSession: session.id, telemetry: .cameraSession, controlAuthority: authority)
    }

    /// Engine input with every listed picture live. `now` is zero: the plans below carry no
    /// deadline and no lease, so no session clock is compared with it (see FindingsTests).
    func state(
        _ entries: [MonitorEntryDescriptor] = [], busy: Set<MonitorEntryID> = []
    ) async -> MulticamSnapshot {
        let pictures = Dictionary(
            entries.compactMap { $0.picture.map { ($0.stream, PictureHealth.live) } }
                + [(hdmi.stream, .live)]
        ) { first, _ in first }
        return await .gather(sessions, pictures: pictures, busy: busy, now: .zero)
    }
}

func group(_ entries: [MonitorEntryDescriptor]) throws -> MulticamGroup {
    var group = MulticamGroup()
    for entry in entries { try group.add(entry) }
    return group
}
