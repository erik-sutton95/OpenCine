import CryptoKit
import Foundation
@testable import Insta360Apple
@testable import Insta360Protocol
import OpenCineCore
import Testing

/// The model gate of the Bluetooth authorization: a Luna Ultra or Luna Pro goes on to the key
/// exchange; any other Insta360 camera on the shared BE80 service is refused by name before
/// anything else is sent. Kotlin mirror: `LunaBluetoothAuthorizationTest`, same method names.
@MainActor @Suite struct LunaBluetoothAuthorizationTests {
    /// A camera behind the Bluetooth link that reports `model` and approves this phone.
    @MainActor private final class Camera {
        let model: String
        private(set) var sent: [LunaCommand] = []
        private(set) var identified: [LunaDeviceInformation] = []
        private let key = P256.KeyAgreement.PrivateKey()

        init(model: String) { self.model = model }

        func authorization() -> LunaBluetoothAuthorization {
            LunaBluetoothAuthorization(
                send: { [self] request in try answer(request) }, agreed: { _ in },
                awaitApproval: { _ in }, appName: "OpenInstaCine",
                identified: { [self] info in identified.append(info) })
        }

        private func answer(_ request: LunaRequest) throws -> Data {
            sent.append(request.command)
            switch request.command {
            case .getOptions where request.body == LunaProtocol.wifiCredentialsRequest.body: return Data()
            case .getOptions:
                return blob(1, Data([48, 15, 30])) + blob(2, blob(15, Data("SN-LUNA".utf8))
                    + blob(30, Data("1.2.7".utf8)) + blob(48, Data(model.utf8)))
            case .encryptionCapabilities: return try ProtoMessage.integer(field: 1, value: 3)
            case .keyExchange:
                return try ProtoMessage.integer(field: 1, value: 1)
                    + ProtoMessage.blob(field: 2, value: key.publicKey.x963Representation)
            case .checkAuthorization:
                return try ProtoMessage.integer(field: 1, value: LunaAuthorizationStatus.authorized.rawValue)
            default: return Data()
            }
        }

        private func blob(_ field: Int, _ value: Data) -> Data { try! ProtoMessage.blob(field: field, value: value) }
    }

    @Test func aLunaUltraOrLunaProIsAuthorized() async throws {
        for model in LunaModel.supported {
            let camera = Camera(model: model.reportedName)
            let result = try await camera.authorization().run(identity: UUID())
            #expect(result.serial == "SN-LUNA")
            #expect(camera.identified.map(\.lunaModel) == [model])
            #expect(camera.sent.contains(.keyExchange) && camera.sent.contains(.checkAuthorization))
        }
    }

    @Test func anotherInsta360CameraIsRefusedByName() async throws {
        for (model, message) in [
            ("Insta360 ONE RS", "This camera is Insta360 ONE RS. OpenInstaCine currently supports the Insta360 Luna Ultra and Luna Pro."),
            ("Insta360 Luna Max", "This camera is Insta360 Luna Max, a Luna model OpenInstaCine does not support yet. "
                + "OpenInstaCine currently supports the Insta360 Luna Ultra and Luna Pro."),
        ] {
            let camera = Camera(model: model)
            do {
                _ = try await camera.authorization().run(identity: UUID())
                Issue.record("\(model) was authorized")
            } catch let failure as ConnectionFailure {
                #expect(failure.reason == .unsupported)
                #expect(failure.code == "com.opencapture.insta360.luna.model.unsupported")
                #expect(failure.message == message)
            }
            #expect(camera.sent == [.getOptions], "nothing past the identity read reaches \(model)")
            #expect(camera.identified.isEmpty)
        }
    }
}
