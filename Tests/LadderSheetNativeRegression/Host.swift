import MonitorUI
import Observation
import OpenCineAppKit
import OpenCineCameraControls
import OpenCineCameraVocabulary
import OpenCineCore
import OpenCineCoreTestSupport
import SwiftUI

/// SIMULATED, developer-only native test host. This target is never a package product.
@main
struct SIMULATEDLadderHost: App {
    @State private var fixture = LadderFixture()

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 8) {
                Text("SIMULATED shared label ladder")
                Text(fixture.status).accessibilityIdentifier("fixture.status")
                if ProcessInfo.processInfo.arguments.contains("tint") {
                    LadderSheet(
                        presentation: fixture.tintPresentation, enabled: true,
                        onWrite: { fixture.tintWrites.append($0.value) },
                        tintLabel: { $0.greenMagenta == 0 && ($0.amberBlue ?? 0) == 0
                            ? "Neutral" : "A\($0.amberBlue ?? 0) G\($0.greenMagenta)" })
                        .environment(\.ladderOperatorHaptics, false)
                } else if let editor = fixture.control.edit(.iso) {
                    LadderSheet(
                        presentation: fixture.presentation, enabled: true,
                        onWrite: { fixture.write($0, editor: editor) },
                        onHold: { fixture.holds += 1 })
                        .environment(\.ladderOperatorHaptics, false)
                }
                HStack {
                    Button("Flush command") { fixture.clock.advance(by: .milliseconds(120)) }
                    Button("Report camera") { Task { await fixture.camera.advance(by: .seconds(3)) } }
                }
            }
            .padding(24).background(Color.black).preferredColorScheme(.dark)
            .task { await fixture.start() }
        }
    }
}

@MainActor @Observable
private final class LadderFixture {
    let clock: LadderClock
    let control: MonitorControlModel
    let camera: FakeCameraSession
    private var backend: CountedLadderBackend?
    var hostCalls = 0
    var accepted = 0
    var wire: [String] = []
    var submitted = "none"
    var holds = 0
    var tintWrites: [String] = []

    init() {
        let clock = LadderClock()
        self.clock = clock
        control = MonitorControlModel(sleep: { await clock.sleep($0) })
        let mode = FakeMode(
            .init(role: .photo, id: "SIMULATED.photo", title: "SIMULATED"),
            [.init(.iso, access: .readWrite, domain: SettingDomain(choices: [
                .iso(.manual(100)), .iso(.manual(200)), .iso(.manual(400)),
            ]))], unsupported: [])
        camera = FakeCameraSession(
            behavior: FakeCameraBehavior(
                integration: .init("SIMULATED"), reportDelay: .seconds(3),
                observationTimeout: .seconds(5), recordWire: .explicit, modes: [1: mode]),
            device: FakeDevice(rawMode: 1, settings:
                ProcessInfo.processInfo.arguments.contains("known") ? [.iso(.manual(200))] : []))
    }

    func start() async {
        let backend = CountedLadderBackend(camera: camera) { [weak self] command, wire in
            self?.wire = wire
            if case .set(.iso(.manual(let value))) = command.intent {
                self?.submitted = "iso:\(value)"
            } else {
                self?.submitted = "unexpected"
            }
        }
        self.backend = backend
        await camera.cameraReportsStatus()
        control.bind(backend)
    }

    var presentation: LadderSheetPresentation<String> {
        LadderSheetPresentation(
            title: "SIMULATED ISO", subtitle: "",
            tabs: [LadderTab(
                label: "ISO", key: "iso",
                ladder: CaptureLadder(
                    current: label(control.snapshot?.value(of: .iso).value),
                    values: ProcessInfo.processInfo.arguments.contains("empty") ? [] : ["100", "200", "400"],
                    lock: ProcessInfo.processInfo.arguments.contains("locked") ? .cameraControl : nil))])
    }

    /// One Tint tab, off neutral, so a reset is visible.
    var tintPresentation: LadderSheetPresentation<String> {
        LadderSheetPresentation(
            title: "SIMULATED WB", subtitle: "",
            tabs: [LadderTab(
                label: "Tint", key: "tint", ladder: CaptureLadder(current: nil, values: []),
                tint: CaptureTint(greenMagenta: 2, amberBlue: 2, range: -6...6))])
    }

    var status: String {
        "tintWrites=\(tintWrites.count) tint=\(tintWrites.last ?? "none") "
            + "observed=\(label(control.snapshot?.value(of: .iso).value) ?? "unknown") "
            + "pending=\(label(control.pending[.iso]) ?? "unknown") "
            + "host=\(hostCalls) accepted=\(accepted) wire=\(wire.count) "
            + "submitted=\(submitted) sleepers=\(clock.pendingSleeps) holds=\(holds)"
    }

    func write(_ write: LadderWrite<String>, editor: MonitorControlModel.Editor) {
        hostCalls += 1
        guard write.key == "iso", let value = Int(write.value) else { return }
        if control.commit(.iso(.manual(value)), from: editor, label: write.value) { accepted += 1 }
    }

    private func label(_ value: SettingValue?) -> String? {
        if case .iso(.manual(let value)) = value { return String(value) }
        return nil
    }
}

/// Counts the actual backend wire after the real control has admitted and submitted a command.
private actor CountedLadderBackend: CameraSession {
    nonisolated let id: CameraSessionID
    let camera: FakeCameraSession
    let submitted: @MainActor @Sendable (CameraCommand, [String]) -> Void

    init(camera: FakeCameraSession, submitted: @escaping @MainActor @Sendable (CameraCommand, [String]) -> Void) {
        self.camera = camera
        id = camera.id
        self.submitted = submitted
    }

    func snapshots() async -> AsyncStream<CameraSnapshot> { await camera.snapshots() }
    func submit(_ command: CameraCommand) async -> CommandReceipt {
        let receipt = await camera.submit(command)
        await submitted(command, camera.wire)
        return receipt
    }
    func outcome(of operation: OperationID) async -> CommandReceipt? { await camera.outcome(of: operation) }
    func receipt(of operation: OperationID) async -> CommandReceipt? { await camera.receipt(of: operation) }
    func close(_ reason: SessionCloseReason) async { await camera.close(reason) }
}

@MainActor @Observable
private final class LadderClock {
    private var now = Duration.zero
    private var sleepers: [(Duration, CheckedContinuation<Void, Never>)] = []
    var pendingSleeps: Int { sleepers.count }

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { sleepers.append((now + duration, $0)) }
    }

    func advance(by duration: Duration) {
        now += duration
        let due = sleepers.filter { $0.0 <= now }
        sleepers.removeAll { $0.0 <= now }
        for (_, continuation) in due { continuation.resume() }
    }
}
