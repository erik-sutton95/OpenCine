#if DEBUG
    import Foundation
    import OpenCineMedia

    /// Explicit development launch only (`OPV_RELIABILITY_VERIFY`): isolated consent, no camera
    /// UI, a synthetic incident through the real recorder, and a status file the verification
    /// driver polls. The app passes its reporting runtime and the reporting SDK's two calls;
    /// release builds compile none of it.
    public struct ReliabilityReportingVerification: Sendable {
        public static var mode: String? {
            let value = ProcessInfo.processInfo.environment["OPV_RELIABILITY_VERIFY"]
            return ["incident", "gatedIncident", "crash", "hang", "resume"].contains(value ?? "")
                ? value : nil
        }

        public let reporting: ReliabilityReporting
        /// The reporting SDK is running.
        public let sdkEnabled: @Sendable () -> Bool
        /// Crashes through the reporting SDK.
        public let crash: @Sendable () -> Void
        /// The application is in the foreground.
        public let isActive: @MainActor @Sendable () -> Bool

        public init(
            reporting: ReliabilityReporting, sdkEnabled: @escaping @Sendable () -> Bool,
            crash: @escaping @Sendable () -> Void,
            isActive: @escaping @MainActor @Sendable () -> Bool
        ) {
            self.reporting = reporting
            self.sdkEnabled = sdkEnabled
            self.crash = crash
            self.isActive = isActive
        }

        /// The camera path a `gatedIncident` run holds for its first 30 seconds.
        private final class Hold: @unchecked Sendable {
            var lease: ReliabilityCameraPathLease?
        }
        private let hold = Hold()

        public func prepareIfRequested() {
            guard Self.mode != nil,
                let defaults = UserDefaults(suiteName: "opc.reliability.verification")
            else { return }
            reporting.consent.defaults = defaults
            reporting.consent.setOptedIn(true)
            reporting.sdkCacheRoot = reporting.sdkCacheRoot
                .appendingPathComponent("verification", isDirectory: true)
            if Self.mode == "gatedIncident" {
                hold.lease = reporting.beginCameraPath()
            }
        }

        public func runIfRequested() {
            guard let mode = Self.mode else { return }
            let id =
                UUID(
                    uuidString:
                        ProcessInfo.processInfo.environment["OPV_RELIABILITY_VERIFY_ID"] ?? "")
                ?? UUID()
            poll(mode: mode, id: id.uuidString, remaining: 60, captured: false)
        }

        private func poll(mode: String, id: String, remaining: Int, captured: Bool) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    if mode == "gatedIncident", remaining == 30 {
                        hold.lease?.end()
                    }
                    let ready = sdkEnabled()
                    var submitted = captured
                    if ready, !captured {
                        if mode == "crash" {
                            writeStatus(id: id, phase: "crashing")
                            crash()
                            return
                        }
                        if mode == "hang", remaining <= 55, isActive() {
                            writeStatus(id: id, phase: "hanging")
                            // Deliberate main-thread stall, confined to this explicit Debug probe.
                            Thread.sleep(forTimeInterval: 5)
                            submitted = true
                        }
                        if ["incident", "gatedIncident"].contains(mode),
                            let bundle = syntheticIncident(id: id)
                        {
                            reporting.setFinalizedSpoolLoader { [bundle] }
                            submitted = true
                        }
                    }
                    reporting.enqueueFinalizedFromSpool()
                    writeStatus(id: id, phase: ready ? "capturing" : "starting")
                    if remaining > 0 {
                        poll(mode: mode, id: id, remaining: remaining - 1, captured: submitted)
                    }
                }
            }
        }

        @MainActor private func writeStatus(id: String, phase: String) {
            let status: [String: Any] = [
                "id": id, "phase": phase, "sdkEnabled": sdkEnabled(),
                "uploadBlocked": reporting.gate.shouldBlockUpload,
                "receipt": reporting.receipt(for: id)?.state.rawValue ?? "none",
                "applicationActive": isActive(),
            ]
            guard
                let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                    .first,
                let data = try? JSONSerialization.data(withJSONObject: status, options: .sortedKeys)
            else { return }
            try? data.write(
                to: root.appendingPathComponent("reliability-verification.json"), options: .atomic)
        }

        public func syntheticIncident(id: String) -> FeedIncidentBundle? {
            var recorder = FeedIncidentRecorder(makeIncidentID: { id })
            _ = recorder.beginSession(
                FeedIncidentSessionContext(
                    sessionID: UUID().uuidString,
                    appVersion: reporting.host.version,
                    appBuild: reporting.host.build,
                    sourceRevision: reporting.host.sourceRevision,
                    osName: "iOS", osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    hardwareClass: "verification", cameraFamily: "synthetic",
                    testSource: .verification,
                    buildIdentity: reporting.origin.currentBuildIdentity()))
            let now = Date()
            func snapshot(_ time: Double, healthy: Bool) -> FeedIncidentSnapshot {
                FeedIncidentSnapshot(
                    monotonicNow: time, wallClock: now,
                    rates: FeedIncidentRates(
                        packetHz: 25, accessUnitHz: 25, decodeSubmitHz: 25,
                        decodeAcceptHz: 25,
                        decodedOutputHz: healthy ? 25 : 0, presentHz: healthy ? 25 : 0),
                    ages: FeedIncidentAges(
                        packetAge: 0.04, accessUnitAge: 0.04, decodeAcceptAge: 0.04,
                        decodedOutputAge: healthy ? 0.04 : 3, presentAge: healthy ? 0.04 : 3),
                    lifecycle: FeedIncidentLifecycle(connected: true, liveEstablished: true))
            }
            _ = recorder.recordSnapshot(snapshot(1, healthy: true))
            recorder.recordBreadcrumb(FeedIncidentBreadcrumb(monotonicAt: 2, kind: .settingsEnter))
            _ = recorder.recordSnapshot(snapshot(4, healthy: false))
            _ = recorder.recordSnapshot(snapshot(5, healthy: true))
            return recorder.recordSnapshot(snapshot(36, healthy: true))?.bundle
        }
    }
#endif
