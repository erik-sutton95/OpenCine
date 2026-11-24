import Foundation
import Observation
import SystemExtensions

/// Installs the one shared driver. Activation runs only when the installed driver differs from the
/// one this dock carries, because repeated replacement is what macOS handles worst.
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
    private var embeddedVersion: String? {
        Bundle(
            url: Bundle.main.bundleURL.appendingPathComponent(
                "Contents/Library/SystemExtensions/\(extensionID).systemextension")
        )?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
    private var activeRequest: OSSystemExtensionRequest?
    private(set) var state = State.checking {
        didSet {
            // A module that started before the driver existed never sees its input appear.
            if state == .installed, oldValue == .awaitingApproval || oldValue == .notInstalled {
                onDriverArrived?()
            }
        }
    }
    @ObservationIgnored var onDriverArrived: (() -> Void)?
    private var installAfterCheck = false
    /// macOS sends nothing to a later launch when the owner approves, so the dock asks again.
    private var approvalPoll: Task<Void, Never>?

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
        watchForApproval()
    }

    private func watchForApproval() {
        guard approvalPoll == nil else { return }
        approvalPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.state == .awaitingApproval else { break }
                if self.activeRequest == nil {
                    self.submit(
                        .propertiesRequest(
                            forExtensionWithIdentifier: self.extensionID, queue: .main))
                }
            }
            self?.approvalPoll = nil
        }
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
        let current = live.filter { $0.bundleVersion == embeddedVersion }
        if current.contains(where: \.isEnabled) {
            state = .installed
        } else if current.contains(where: \.isAwaitingUserApproval) {
            state = .awaitingApproval
            watchForApproval()
        } else if installAfterCheck {
            installAfterCheck = false
            state = .notInstalled
            submit(.activationRequest(forExtensionWithIdentifier: extensionID, queue: .main))
        } else {
            state = live.contains(where: \.isEnabled) ? .installed : .notInstalled
        }
    }
}
