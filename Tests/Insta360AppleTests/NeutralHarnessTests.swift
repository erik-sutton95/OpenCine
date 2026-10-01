import Insta360Apple
import OpenCineCore
import XCTest

/// VENDOR-03 gate: a harness with no app builds the Luna integration and its common session from
/// this package alone, naming itself through the configuration. Nothing here is process-wide.
@MainActor
final class NeutralHarnessTests: XCTestCase {
    private let harness = LunaIntegrationConfiguration(
        keychainService: "org.opencine.insta360.harness", appName: "Harness", logPrefix: "harness")

    func testAHarnessBuildsALunaSessionFromThePackageAlone() async {
        let backend = LunaCameraBackend(configuration: harness)
        XCTAssertEqual(backend.configuration, harness)
        XCTAssertNil(backend.storedWiFi(cameraID: UUID()), "nothing saved under the harness service")

        let session = backend.openSession()
        XCTAssertTrue(backend.session === session)
        XCTAssertNotNil(session.current.capabilities[.iso], "the session describes Luna's settings")
        XCTAssertNotEqual(session.current.connection, .ready)

        // No link yet: the command is refused by the session, never sent blind.
        let command = CameraCommand(
            .set(.iso(.manual(800))), preconditions: CommandPreconditions(session.current))
        guard case .rejected = await session.submit(command).stage else {
            return XCTFail("a session without a link must reject")
        }

        // A new connection's session replaces the old one, which ends as replaced.
        let next = backend.openSession()
        XCTAssertTrue(backend.session === next)
        XCTAssertEqual(session.current.connection, .disconnected(.replaced))
    }

    func testTwoIntegrationInstancesShareNothing() {
        let a = LunaCameraBackend(configuration: harness)
        let b = LunaCameraBackend()
        XCTAssertEqual(b.configuration.keychainService, "org.opencine.openinstacine.camera",
            "the default keeps OpenInstaCine's saved camera credentials readable")
        var seenByB: [CameraBackendEvent] = []
        b.eventHandler = { seenByB.append($0) }
        let sessionA = a.openSession()
        a.eventHandler?(.note("only A"))
        XCTAssertNil(b.session)
        XCTAssertTrue(seenByB.isEmpty)
        let sessionB = b.openSession()
        XCTAssertNotEqual(sessionA.id, sessionB.id)
        XCTAssertNotEqual(sessionA.current.connection, .disconnected(.replaced))
    }
}
