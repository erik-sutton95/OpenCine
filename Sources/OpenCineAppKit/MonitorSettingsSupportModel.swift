import Foundation
import Observation

public struct MonitorSettingsBrowserDestination: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let url: URL
    public let confirmationMessage: String
    public init(id: String, title: String, url: URL, confirmationMessage: String) {
        self.id = id; self.title = title; self.url = url; self.confirmationMessage = confirmationMessage
    }
}

/// The host could not write a diagnostic report; the message names the host's support address.
public struct MonitorSettingsReportUnavailable: LocalizedError, Equatable, Sendable {
    public let supportEmail: String
    public init(supportEmail: String) { self.supportEmail = supportEmail }
    public var errorDescription: String? { "This phone couldn't save the report. Email \(supportEmail) instead." }
}

/// Captured browser cleanup stays on the route that prepared this handoff.
@MainActor
public struct MonitorSettingsBrowserHandoff {
    let isCurrent: () -> Bool
    let complete: (Bool) async -> Void
    public init(isCurrent: @escaping () -> Bool, complete: @escaping (Bool) async -> Void) {
        self.isCurrent = isCurrent; self.complete = complete
    }
}

@MainActor
public struct MonitorSettingsSupportActions {
    public let identity: AnyHashable
    let isCurrent: () -> Bool
    public let requiresInternetConsent: Bool?
    let makeReport: () async throws -> URL
    let prepareBrowser: (@escaping @MainActor () -> Bool) async -> MonitorSettingsBrowserHandoff?
    let open: (URL) async -> Bool
    let preparationChanged: (String?) -> Void
    let internetFailure: String?
    public init(identity: AnyHashable, isCurrent: @escaping () -> Bool, requiresInternetConsent: Bool?,
        makeReport: @escaping () async throws -> URL,
        prepareBrowser: @escaping (@escaping @MainActor () -> Bool) async -> MonitorSettingsBrowserHandoff?,
        open: @escaping (URL) async -> Bool, preparationChanged: @escaping (String?) -> Void = { _ in },
        internetFailure: String? = nil) {
        self.identity = identity; self.isCurrent = isCurrent; self.requiresInternetConsent = requiresInternetConsent
        self.makeReport = makeReport; self.prepareBrowser = prepareBrowser; self.open = open
        self.preparationChanged = preparationChanged; self.internetFailure = internetFailure
    }
}

/// Settings owns report preparation and browser consent; native adapters own report and route IO.
@available(macOS 14, *)
@MainActor @Observable
public final class MonitorSettingsSupportModel {
    private struct State: Equatable {
        var preparingReport = false
        var reportURL: URL?
        var reportFailed = false
        var reportFailure: String?
        var confirmation: MonitorSettingsBrowserDestination?
        var preparingBrowser = false
        var browserFailed = false
        var browserFailure: String?
    }
    private struct Confirmation {
        let destination: MonitorSettingsBrowserDestination
        let source: MonitorSettingsSupportActions
        let generation: UInt64
    }
    private enum Field: Equatable { case reportBusy, reportURL, reportFailed, reportFailure, confirmation, browserBusy, browserFailed, browserFailure, revision }
    private final class Run {
        let source: MonitorSettingsSupportActions
        let generation: UInt64
        var task: Task<Void, Never>?
        init(source: MonitorSettingsSupportActions, generation: UInt64) {
            self.source = source; self.generation = generation
        }
    }
    @ObservationIgnored private var state = State()
    @ObservationIgnored private var source: MonitorSettingsSupportActions?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var confirmation: Confirmation?
    @ObservationIgnored private var reportRun: Run?
    @ObservationIgnored private var browserRun: Run?
    @ObservationIgnored private var notifying = false
    @ObservationIgnored private var pending: [Field] = []
    public var preparingReport: Bool { access(keyPath: \.preparingReport); return state.preparingReport }
    public var reportURL: URL? { access(keyPath: \.reportURL); return state.reportURL }
    public var reportFailed: Bool { access(keyPath: \.reportFailed); return state.reportFailed }
    public var reportFailure: String? { access(keyPath: \.reportFailure); return state.reportFailure }
    public var destination: MonitorSettingsBrowserDestination? { access(keyPath: \.destination); return state.confirmation }
    public var preparingBrowser: Bool { access(keyPath: \.preparingBrowser); return state.preparingBrowser }
    public var browserFailed: Bool { access(keyPath: \.browserFailed); return state.browserFailed }
    public var browserFailure: String? { access(keyPath: \.browserFailure); return state.browserFailure }
    @ObservationIgnored private var revision: UInt64 = 0
    public var snapshotRevision: UInt64 { access(keyPath: \.snapshotRevision); return revision }
    public init() {}

    public func bind(_ next: MonitorSettingsSupportActions) {
        guard source?.identity != next.identity else { source = next; return }
        retire()
        guard source == nil else { return }
        source = next
    }
    public func prepareReport() {
        let capturedGeneration = generation
        guard reportRun == nil, let captured = source, admits(captured, capturedGeneration) else { return }
        let run = Run(source: captured, generation: capturedGeneration); reportRun = run
        run.task = Task { @MainActor [weak self] in
            guard let self, self.admitsReport(run) else { return }
            do {
                let url = try await captured.makeReport()
                guard self.admitsReport(run) else { return }
                self.reportRun = nil; run.task = nil
                var next = self.state; next.preparingReport = false; next.reportURL = url; self.publish(next)
            } catch {
                guard self.admitsReport(run) else { return }
                self.reportRun = nil; run.task = nil
                var next = self.state; next.preparingReport = false; next.reportFailed = true
                next.reportFailure = self.reportedMessage(error); self.publish(next)
            }
        }
        var next = state; next.preparingReport = true; next.reportFailed = false; next.reportFailure = nil; publish(next)
    }
    public func request(_ destination: MonitorSettingsBrowserDestination) {
        let capturedGeneration = generation
        guard let captured = source, admits(captured, capturedGeneration) else { return }
        if captured.requiresInternetConsent == true {
            confirmation = .init(destination: destination, source: captured, generation: capturedGeneration)
            var next = state; next.confirmation = destination; publish(next)
        } else { startBrowser(destination, source: captured, generation: capturedGeneration) }
    }
    public func confirmBrowser() {
        let captured = confirmation
        cancelConfirmation()
        if let captured { startBrowser(captured.destination, source: captured.source, generation: captured.generation) }
    }
    public func cancelConfirmation() {
        confirmation = nil
        var next = state; next.confirmation = nil; publish(next)
    }
    public func dismissReport() { var next = state; next.reportURL = nil; publish(next) }
    public func dismissError() {
        var next = state; next.reportFailed = false; next.reportFailure = nil
        next.browserFailed = false; next.browserFailure = nil; publish(next)
    }
    public func retire() {
        let outgoingSource = browserRun?.source
        generation &+= 1; source = nil; confirmation = nil
        let retiredGeneration = generation
        let report = reportRun, browser = browserRun; reportRun = nil; browserRun = nil
        report?.task?.cancel(); browser?.task?.cancel()
        publish(State())
        if generation == retiredGeneration, source == nil { outgoingSource?.preparationChanged(nil) }
    }
    private func startBrowser(_ destination: MonitorSettingsBrowserDestination,
        source captured: MonitorSettingsSupportActions, generation capturedGeneration: UInt64) {
        guard admits(captured, capturedGeneration) else { return }
        let previous = browserRun
        let enteredCleanup = previous?.task
        let run = Run(source: captured, generation: capturedGeneration); browserRun = run
        run.task = Task { @MainActor [weak self] in
            await enteredCleanup?.value
            guard let self, self.admitsBrowser(run) else { return }
            let handoff = await captured.prepareBrowser { [weak self, weak run] in
                guard let self, let run else { return false }; return self.admitsBrowser(run)
            }
            var accepted = false
            var ready = false
            if let handoff, self.admitsBrowser(run) {
                ready = handoff.isCurrent()
                if ready, self.admitsBrowser(run) { accepted = await captured.open(destination.url) }
            }
            let current = self.admitsBrowser(run)
            if let handoff {
                let routeCurrent = handoff.isCurrent()
                await handoff.complete(accepted && current && routeCurrent && self.admitsBrowser(run))
            }
            guard self.admitsBrowser(run) else { return }
            captured.preparationChanged(nil)
            guard self.admitsBrowser(run) else { return }
            self.browserRun = nil; run.task = nil
            var next = self.state; next.preparingBrowser = false; next.browserFailed = !ready
            next.browserFailure = ready ? nil : captured.internetFailure; self.publish(next)
        }
        previous?.task?.cancel()
        var next = state; next.preparingBrowser = true; next.browserFailed = false; next.browserFailure = nil; publish(next)
        if admitsBrowser(run) { captured.preparationChanged(captured.requiresInternetConsent == true ? destination.title : nil) }
    }
    private func admits(_ captured: MonitorSettingsSupportActions, _ capturedGeneration: UInt64) -> Bool {
        guard generation == capturedGeneration, source?.identity == captured.identity else { return false }
        let current = captured.isCurrent()
        return current && generation == capturedGeneration && source?.identity == captured.identity
    }
    private func admitsReport(_ run: Run) -> Bool {
        guard reportRun === run, !Task.isCancelled else { return false }
        let current = admits(run.source, run.generation)
        return current && reportRun === run && !Task.isCancelled
    }
    private func admitsBrowser(_ run: Run) -> Bool {
        guard browserRun === run, !Task.isCancelled else { return false }
        let current = admits(run.source, run.generation)
        return current && browserRun === run && !Task.isCancelled
    }
    private func reportedMessage(_ error: any Error) -> String? {
        (error as? any LocalizedError)?.errorDescription
            ?? (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String
    }
    private func publish(_ next: State) {
        guard state != next else { return }
        let old = state; state = next; revision &+= 1
        let changed: [(Field, Bool)] = [(.reportBusy, old.preparingReport != next.preparingReport),
            (.reportURL, old.reportURL != next.reportURL), (.reportFailed, old.reportFailed != next.reportFailed),
            (.reportFailure, old.reportFailure != next.reportFailure), (.confirmation, old.confirmation != next.confirmation),
            (.browserBusy, old.preparingBrowser != next.preparingBrowser), (.browserFailed, old.browserFailed != next.browserFailed),
            (.browserFailure, old.browserFailure != next.browserFailure), (.revision, true)]
        for (field, changes) in changed where changes && !pending.contains(field) { pending.append(field) }
        guard !notifying else { return }
        notifying = true
        while !pending.isEmpty {
            switch pending.removeFirst() {
            case .reportBusy: withMutation(keyPath: \.preparingReport) {}
            case .reportURL: withMutation(keyPath: \.reportURL) {}
            case .reportFailed: withMutation(keyPath: \.reportFailed) {}
            case .reportFailure: withMutation(keyPath: \.reportFailure) {}
            case .confirmation: withMutation(keyPath: \.destination) {}
            case .browserBusy: withMutation(keyPath: \.preparingBrowser) {}
            case .browserFailed: withMutation(keyPath: \.browserFailed) {}
            case .browserFailure: withMutation(keyPath: \.browserFailure) {}
            case .revision: withMutation(keyPath: \.snapshotRevision) {}
            }
        }
        notifying = false
    }
}
