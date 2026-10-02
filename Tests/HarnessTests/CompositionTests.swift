import Foundation
import HarnessComposition
import HarnessEngine
import Insta360Apple
import Insta360AppleTestSupport
import OpenCineCore
import OpenCineDJI
import OpenCineMulticam
import OpenCineNikon
import Testing

/// SIMULATED. Plan 13 MULTI-03 step 1: DJI, Nikon and Luna sessions composed in one process
/// through one dependency closure, with no global runtime collision.
@MainActor
@Suite struct CompositionTests {
    @Test func theCompositionRootListsEachIntegrationOnce() {
        let ids = Composition.factories.map(\.id)
        #expect(
            ids == [
                DJICameraSessionAdapter.integration, NikonCameraSession.integration,
                LunaCameraSession.integration, Composition.hdmiCapture.id,
            ])
        #expect(Set(ids).count == ids.count)
        // Luna offers only its own access point (plan 8.4): never a shared network.
        #expect(Composition.luna.routes.map(\.kind) == [.cameraAccessPoint])
        #expect(Composition.hdmiCapture.routes.allSatisfy { $0.picture && !$0.control })
    }

    @Test func threeIntegrationsShareOneProcessAndOneCoreTypeSystem() async throws {
        let rig = Rig()
        // One OpenCineCore module: every session is the same `CameraSession` existential and every
        // snapshot the same `CameraSnapshot`, so the engine takes them in one dictionary.
        let sessions: [any CameraSession] = rig.sessions
        #expect(Set(sessions.map(\.id)).count == 3)
        let state = await rig.state()
        #expect(state.cameras.count == 3)
        let integrations = Set(state.cameras.values.compactMap(\.device?.integration))
        #expect(
            integrations == [
                DJICameraSessionAdapter.integration, NikonCameraSession.integration,
                LunaCameraSession.integration,
            ])
        for snapshot in state.cameras.values {
            #expect(snapshot.connection == .ready)
            #expect(snapshot.authority == .owner)
        }
    }

    @Test func closingOrReplacingOneSessionLeavesTheOthersAlone() async throws {
        let rig = Rig()
        let second = Rig()  // a second camera of every brand in the same process
        rig.luna.close(.replaced)
        rig.dji.close(.requested)
        let after = await rig.state()
        #expect(after.cameras[rig.luna.id]?.connection == .disconnected(.replaced))
        #expect(after.cameras[rig.dji.id]?.connection == .disconnected(.requested))
        #expect(after.cameras[rig.nikon.id]?.connection == .ready)
        let others = await second.state()
        #expect(others.cameras.values.allSatisfy { $0.connection == .ready })
        // Closing never sent a camera command.
        #expect(rig.djiPort.fired.isEmpty)
        #expect(rig.lunaCamera.sent.isEmpty)
    }

    @Test func twoLunaBackendsShareNoCredentialsOrCallbacks() {
        let harness = Composition.lunaBackend()
        let app = LunaCameraBackend()
        #expect(harness.configuration.keychainService == "org.opencapture.harness.luna")
        #expect(app.configuration.keychainService != harness.configuration.keychainService)
        let a = harness.openSession()
        #expect(app.session == nil)
        let b = app.openSession()
        #expect(a.id != b.id)
        #expect(a.current.connection != .disconnected(.replaced))
    }

    /// Plan 13 gate: the shared engine requires no manufacturer branch. The harness's own neutral
    /// module is held to the same rule as OpenCineMulticam and OpenCineCore (whose own tests
    /// enforce it on their sources).
    @Test func neutralCodeNamesNoManufacturer() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../..").standardized
        // OpenCineMulticam lives in the same package. Under Xcode the path may not exist; its own
        // ImportRuleTests hold it to the same rule.
        let multicam = [root.appendingPathComponent("Sources/OpenCineMulticam")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
        let neutral = [root.appendingPathComponent("Sources/HarnessEngine")] + (multicam.map { [$0] } ?? [])
        let forbidden = [
            "OpenCineDJI", "OpenCineNikon", "Insta360", "Luna", "Nikon", "DJI", "Pocket",
            "IntegrationID(", "SwiftUI", "UIKit",
        ]
        var scanned = 0
        for directory in neutral {
            let files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                scanned += 1
                for name in forbidden {
                    #expect(!text.contains(name), "\(file.lastPathComponent) names \(name)")
                }
            }
        }
        #expect(scanned >= (multicam == nil ? 3 : 9))
    }
}
