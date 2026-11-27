import Foundation
import Observation
import OpenCineDesktopKit
import SystemExtensions
import os

private let log = Logger(subsystem: "com.opencapture.opencine", category: "driver")

/// Installs the one shared driver. Activation runs only when the installed driver differs from the
/// one this dock carries, because repeated replacement is what macOS handles worst. After an update
/// the dock checks that the new driver really started before calling it installed.
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
    /// Set when macOS replaces an installed driver, so the finished activation is an update.
    private var replacing = false
    /// While an update's new driver is being looked for.
    private var updateCheck: DriverUpdateCheck?
    private var updateLookup: Task<Void, Never>?

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
    ) -> OSSystemExtensionRequest.ReplacementAction {
        replacing = true
        return .replace
    }

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
        activeRequest = nil
        let wasUpdate = replacing || updateCheck != nil
        replacing = false
        if result == .willCompleteAfterReboot {
            endUpdateCheck()
            state = .restartNeeded
        } else if wasUpdate {
            // Installed only once its inputs appear: macOS can finish an update whose driver never
            // starts.
            if updateCheck == nil { updateCheck = DriverUpdateCheck() }
            lookForUpdatedDriver()
        } else {
            state = .installed
        }
    }

    private func lookForUpdatedDriver() {
        updateLookup?.cancel()
        updateLookup = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let present = await DriverChannel.driverIsPresent()
                guard let self, !Task.isCancelled, var check = self.updateCheck else { return }
                let action = check.looked(driverPresent: present)
                self.updateCheck = check
                switch action {
                case .wait:
                    continue
                case .started:
                    log.notice("The updated camera driver is running")
                    self.endUpdateCheck()
                    self.state = .installed
                case .activateAgain:
                    log.error("The updated camera driver did not start; activating it again")
                    self.updateLookup = nil
                    self.submit(
                        .activationRequest(
                            forExtensionWithIdentifier: self.extensionID, queue: .main))
                case .restartNeeded:
                    log.error("The updated camera driver did not start; a restart is needed")
                    self.endUpdateCheck()
                    self.state = .restartNeeded
                }
                return
            }
        }
    }

    private func endUpdateCheck() {
        updateLookup?.cancel()
        updateLookup = nil
        updateCheck = nil
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        endUpdateCheck()
        replacing = false
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
