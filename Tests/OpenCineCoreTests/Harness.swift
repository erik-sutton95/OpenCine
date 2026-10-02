import OpenCineCore
import OpenCineCoreTestSupport
import Testing

/// Fixture families. The harness only constructs them; no scenario branches on which one it got.
enum Fixture: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case djiLike
    case nikonLike
    case lunaLike

    var testDescription: String { rawValue }

    func make() -> FakeCameraSession {
        switch self {
        case .djiLike: .djiLike()
        case .nikonLike: .nikonLike()
        case .lunaLike: .lunaLike()
        }
    }
}

/// A camera that has reported once and, where it needs one, runs its own live view.
func reportedCamera(_ fixture: Fixture) async -> FakeCameraSession {
    let camera = fixture.make()
    await camera.cameraReportsStatus()
    await camera.setLiveViewReady(true)
    return camera
}

/// A different valid value for some writable, available setting, chosen from descriptors alone:
/// what a generic control does.
func someChange(in snapshot: CameraSnapshot) -> SettingValue? {
    for key in SettingKey.allCases {
        guard let descriptor = snapshot.capabilities[key], descriptor.access == .readWrite,
            descriptor.availability == .available, let domain = descriptor.domain
        else { continue }
        if let value = domain.choices.first(where: { $0 != snapshot.value(of: key).value }) {
            return value
        }
    }
    return nil
}

extension FakeCameraSession {
    /// A command carrying the assumptions of an operator looking at the current snapshot.
    func command(_ intent: CameraCommandIntent, deadline: MonotonicInstant? = nil) -> CameraCommand {
        CameraCommand(intent, preconditions: CommandPreconditions(current, deadline: deadline))
    }

    func submit(_ intent: CameraCommandIntent) -> CommandReceipt { submit(command(intent)) }
}
