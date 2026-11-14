import CryptoKit
import Foundation
import Insta360Protocol
import OpenCineCore

/// The Bluetooth authorization a connect and a return to the access point share (Kotlin twin
/// `LunaBluetoothAuthorization`): the camera's identity, the encrypted session, this phone's
/// approval and the encrypted credential read, in the hardware-verified order. Every request goes
/// through `send`, so a test sees each one the camera would receive.
@MainActor
struct LunaBluetoothAuthorization {
    /// One request on the Bluetooth link; returns the camera's 200 body. Encrypted requests use
    /// the key `agreed` received.
    var send: @MainActor (LunaRequest) async throws -> Data
    /// The session key the exchange agreed.
    var agreed: @MainActor (SymmetricKey) -> Void
    /// Waits for the operator to approve this phone on the camera (after request 86).
    var awaitApproval: @MainActor (UUID) async throws -> Void
    /// The app's name in the unsupported-camera message.
    var appName: String
    /// The connect phase each step starts; a return to the access point reports none.
    var phase: @MainActor (CameraConnectionPhase) -> Void = { _ in }
    /// The camera's identity once Bluetooth read it.
    var identified: @MainActor (LunaDeviceInformation) -> Void = { _ in }

    /// The serial Bluetooth read and the credential read's reply.
    func run(identity: UUID) async throws -> (serial: String, credentials: Data) {
        phase(.negotiating)
        let info = try LunaProtocol.deviceInformation(
            response: await send(LunaProtocol.deviceInformationRequest(includeSerial: true)))
        // BE80 is shared by more Insta360 cameras. Only apply the verified Luna profile.
        guard info.model == LunaProtocol.model else {
            throw ConnectionFailure.luna(
                .unsupported, "model.unsupported",
                "This camera is \(info.model). \(appName) currently supports the Insta360 Luna Ultra.",
                phase: .negotiating)
        }
        guard let serial = info.serial, !serial.isEmpty else {
            throw ConnectionFailure.luna(
                .other, "serial.missing",
                "The camera did not provide an identity to verify its Wi-Fi handoff.",
                phase: .negotiating)
        }
        identified(info)
        let schemes = try LunaProtocol.encryptionSchemes(
            response: await send(LunaProtocol.encryptionCapabilitiesRequest))
        guard schemes.contains(3) else {
            throw ConnectionFailure.luna(
                .unsupported, "encryption.unsupported",
                "The camera does not support the verified encrypted connection handshake.",
                phase: .negotiating)
        }
        let privateKey = P256.KeyAgreement.PrivateKey()
        let exchange = try LunaProtocol.keyExchangeRequest(
            publicKey: privateKey.publicKey.x963Representation)
        let cameraKey = try LunaProtocol.cameraPublicKey(response: await send(exchange))
        let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: cameraKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        agreed(
            secret.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: LunaProtocol.hkdfSalt, sharedInfo: LunaProtocol.hkdfInfo,
                outputByteCount: LunaProtocol.sessionKeyByteCount))
        let authenticated = try LunaProtocol.deviceInformation(
            response: await send(LunaProtocol.deviceInformationRequest(encrypted: true)))
        guard authenticated.model == info.model else {
            throw ConnectionFailure.luna(
                .wrongCamera, "identity.mismatch",
                "The encrypted camera identity did not match the selected device.",
                phase: .negotiating)
        }
        phase(.awaitingApproval)
        let authorization = try LunaProtocol.authorizationStatus(
            response: await send(LunaProtocol.authorizationCheck(identity: identity)))
        if authorization == .approvalRequired {
            _ = try await send(LunaProtocol.requestAuthorization)
            try await awaitApproval(identity)
        } else if authorization != .authorized {
            throw ConnectionFailure.lunaHeldElsewhere
        }
        phase(.readingWiFi)
        let reply = try await send(LunaProtocol.wifiCredentialsRequest)
        return (serial, reply)
    }
}
