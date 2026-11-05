import Foundation
import Observation
import SystemExtensions

/// Installs the one shared driver. Activation runs only when the driver is absent, because
/// repeated replacement is what macOS handles worst.
@MainActor @Observable
final class DriverController: NSObject, @preconcurrency OSSystemExtensionRequestDelegate {
    enum State: Equatable {
        case checking
        case notInstalled
        case awaitingApproval
        case installed
        case restartNeeded
        case failed(String)
    }

    private let extensionID = "com.opencapture.opencine.camera"
    private var activeRequest: OSSystemExtensionRequest?
    private(set) var state = State.checking
    private var installAfterCheck = false

    /// Checks, and installs when absent.
    func ensureInstalled() {
        installAfterCheck = true
        submit(.propertiesRequest(forExtensionWithIdentifier: extensionID, queue: .main))
    }

    private func submit(_ request: OSSystemExtensionRequest) {
        activeRequest = request
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension replacement: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction { .replace }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        state = .awaitingApproval
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        state = result == .willCompleteAfterReboot ? .restartNeeded : .installed
        activeRequest = nil
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        state = .failed(error.localizedDescription)
        activeRequest = nil
    }

    func request(
        _ request: OSSystemExtensionRequest,
        foundProperties properties: [OSSystemExtensionProperties]
    ) {
        activeRequest = nil
        let live = properties.filter { !$0.isUninstalling }
        if live.contains(where: \.isEnabled) {
            state = .installed
        } else if live.contains(where: \.isAwaitingUserApproval) {
            state = .awaitingApproval
        } else if installAfterCheck {
            installAfterCheck = false
            state = .notInstalled
            submit(.activationRequest(forExtensionWithIdentifier: extensionID, queue: .main))
        } else {
            state = .notInstalled
        }
    }
}
