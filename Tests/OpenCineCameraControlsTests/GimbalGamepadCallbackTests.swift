#if os(iOS)
    import GameController
    import XCTest

    @testable import OpenCineCameraControls

    /// PI-3P / PI-3N class: GameController runs the gamepad value handler on the controller's
    /// `handlerQueue`. A handler with main-actor isolation traps on entry from any other queue.
    final class GimbalGamepadCallbackTests: XCTestCase {
        @MainActor
        private final class Runs {
            var count = 0
        }

        @MainActor
        func testAHandlerCalledOffTheMainThreadReachesTheMainActorWithoutTrapping() throws {
            nonisolated(unsafe) let pad = try XCTUnwrap(GCController.withExtendedGamepad().extendedGamepad)
            let runs = Runs()
            let ran = expectation(description: "the body runs on the main actor")
            nonisolated(unsafe) let handler = GimbalGamepadCallback.valueChanged {
                MainActor.preconditionIsolated()
                runs.count += 1
                ran.fulfill()
            }
            DispatchQueue(label: "opc.test.gamepad-handler").async { handler(pad, pad.buttonA) }
            wait(for: [ran], timeout: 5)
            XCTAssertEqual(runs.count, 1)
        }

        @MainActor
        func testOnTheMainThreadTheBodyRunsAtOnce() throws {
            let pad = try XCTUnwrap(GCController.withExtendedGamepad().extendedGamepad)
            let runs = Runs()
            let handler = GimbalGamepadCallback.valueChanged { runs.count += 1 }
            handler(pad, pad.buttonA)
            XCTAssertEqual(runs.count, 1, "no hop, so a press is handled before the next one arrives")
        }
    }
#endif
