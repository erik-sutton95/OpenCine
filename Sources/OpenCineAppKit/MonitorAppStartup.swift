import Foundation
import MonitorPresentation
import Observation
import OpenCineCore

/// Host reporting actions over the app's existing consent store and transport. The startup
/// lifetime owns admission and cadence, never persistence namespaces, SDKs or upload policy.
@MainActor public struct MonitorStartupReports {
    public let isAvailable: () -> Bool
    public let hasDecision: () -> Bool
    public let setConsent: (Bool) -> Void
    public let tick: () -> Void

    public init(
        isAvailable: @escaping () -> Bool, hasDecision: @escaping () -> Bool,
        setConsent: @escaping (Bool) -> Void, tick: @escaping () -> Void
    ) {
        self.isAvailable = isAvailable
        self.hasDecision = hasDecision
        self.setConsent = setConsent
        self.tick = tick
    }

    public init(reporting: ReliabilityReporting, tick: @escaping () -> Void) {
        self.init(
            isAvailable: { reporting.isAvailable },
            hasDecision: { reporting.consent.hasDecision }, setConsent: reporting.setConsent,
            tick: tick)
    }
}

/// One offered choice, fenced to the root run that presented it. A dismissed sheet or an old
/// callback can never decide consent for a replacement root.
@MainActor public struct MonitorStartupConsent: Identifiable {
    public let id: UUID
    public let choose: (Bool) -> Void
}

/// The app root's launch, first-report offer and reporting cadence. SwiftUI adapts its native
/// task and scene lifetime; the transport still decides whether a tick can upload.
@available(macOS 14, *)
@MainActor @Observable public final class MonitorAppStartup {
    public private(set) var consentOffer: MonitorStartupConsent?
    public private(set) var isRetired = true
    @ObservationIgnored private let reports: MonitorStartupReports
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private var runID: UUID?

    public init(
        reports: MonitorStartupReports,
        sleep: @escaping @MainActor (Duration) async throws -> Void = hostSleep(for:)
    ) {
        self.reports = reports
        self.sleep = sleep
    }

    /// Runs until its native task ends. Reentry replaces the previous run, including any old
    /// prompt callback or dependency that returns after cancellation.
    public func run(dismissSplash: @escaping @MainActor @Sendable () -> Void) async {
        let id = UUID()
        runID = id
        isRetired = false
        consentOffer = nil
        defer { if runID == id { retire() } }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in await launch(id, dismissSplash: dismissSplash) }
            group.addTask { [self] in await poll(id) }
            await group.waitForAll()
        }
    }

    private func launch(_ id: UUID, dismissSplash: @MainActor @Sendable () -> Void) async {
        do { try await sleep(MonitorLaunchTiming.visibleDuration) } catch { return }
        guard current(id), !Task.isCancelled else { return }
        dismissSplash()
        guard current(id), reports.isAvailable(), !reports.hasDecision() else { return }
        consentOffer = MonitorStartupConsent(id: id) { [weak self] enabled in
            guard let self, self.current(id), self.consentOffer?.id == id else { return }
            self.reports.setConsent(enabled)
            self.consentOffer = nil
        }
    }

    private func poll(_ id: UUID) async {
        while current(id), !Task.isCancelled {
            reports.tick()
            do { try await sleep(.seconds(2)) } catch { return }
        }
    }

    public func sceneChanged() {
        guard !isRetired else { return }
        reports.tick()
    }

    /// Interactive sheet dismissal records no decision, matching the original host sheets.
    public func dismissConsentOffer() { consentOffer = nil }

    public func retire() {
        runID = nil
        isRetired = true
        consentOffer = nil
    }

    private func current(_ id: UUID) -> Bool { !isRetired && runID == id }
}
