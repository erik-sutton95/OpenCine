import Foundation

/// The camera a diagnostic report describes. Unknown is `"none"`. Kotlin twin: `DiagnosticCamera`.
public struct DiagnosticCamera: Equatable, Sendable {
    public var family: String
    public var model: String
    public var phase: String

    public init(family: String, model: String, phase: String) {
        self.family = family
        self.model = model
        self.phase = phase
    }
}

#if os(iOS)
    import OpenCineAppKit
    import OpenCineApple
    import OpenCineMedia
    import UIKit
    import os

    /// On-device diagnostics the camera apps share: unified log, capped journal, exceptions,
    /// MetricKit, and a shareable report. Optional uploads belong to ReliabilityReporting. Personal
    /// name, location, device name, and Wi-Fi passwords are stripped with the host's redaction
    /// before a line is stored.
    ///
    /// Each app keeps one `DiagnosticCenter` subclass with its `Host` and how it reads its session's
    /// camera. Kotlin twin: `DiagnosticCenterRuntime` in appkit. Observers and MetricKit call in from
    /// any thread; operator-facing work hops to the main actor.
    open class DiagnosticCenterRuntime: NSObject, @unchecked Sendable {
        /// What one app supplies: its name and log subsystem, its journal and redaction policy, its
        /// incident runtime and Local Network status, and the camera of the session it shows now.
        public struct Host {
            public var product: String
            public var subsystem: String
            public var journal: DiagnosticJournal
            public var redact: @Sendable (String) -> String
            /// A camera access point name the report may keep readable.
            public var isSafeNetwork: @Sendable (String) -> Bool
            /// The app's incident runtime, read when first used (as the app's own static).
            public var incidents: () -> FeedIncidentRuntime
            public var localNetwork: @MainActor () -> String
            /// The shown session's camera for the screenshot paste; nil before the app has one.
            public var currentCamera: @MainActor () -> DiagnosticCamera?

            public init(
                product: String, subsystem: String, journal: DiagnosticJournal,
                redact: @escaping @Sendable (String) -> String,
                isSafeNetwork: @escaping @Sendable (String) -> Bool,
                incidents: @escaping () -> FeedIncidentRuntime,
                localNetwork: @escaping @MainActor () -> String,
                currentCamera: @escaping @MainActor () -> DiagnosticCamera?
            ) {
                self.product = product
                self.subsystem = subsystem
                self.journal = journal
                self.redact = redact
                self.isSafeNetwork = isSafeNetwork
                self.incidents = incidents
                self.localNetwork = localNetwork
                self.currentCamera = currentCamera
            }
        }

        public let host: Host
        private let log: Logger
        private let signposter: OSSignposter
        private var screenshotObserver: NSObjectProtocol?
        private var memoryObserver: NSObjectProtocol?
        /// Uptime of the last `didReceiveMemoryWarning` (main thread).
        public private(set) var lastMemoryWarningUptime: TimeInterval?
        private var installed = false

        /// Last compact summary copied for TestFlight paste.
        public private(set) var lastCompactSummary = ""
        public var onCopiedForTestFlight: (() -> Void)?

        public init(host: Host) {
            self.host = host
            log = Logger(subsystem: host.subsystem, category: "diagnostics")
            signposter = OSSignposter(subsystem: host.subsystem, category: "diagnostics")
            super.init()
        }

        public nonisolated static var documentsURL: URL? {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        }

        public nonisolated static var diagnosticsDirectory: URL? {
            guard let docs = documentsURL else { return nil }
            let dir = docs.appendingPathComponent("diagnostics", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        public nonisolated static var exceptionsURL: URL? {
            diagnosticsDirectory?.appendingPathComponent("exceptions.log")
        }

        @MainActor
        public func install() {
            guard !installed else { return }
            installed = true
            metricSubscriber.start()
            DiagnosticExceptionHandler.install { [self] exception in
                recordUncaught(exception)
            }
            screenshotObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.userDidTakeScreenshotNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.copyCompactSummaryForTestFlight()
                }
            }
            memoryObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.lastMemoryWarningUptime = ProcessInfo.processInfo.systemUptime
                let megabytes = os_proc_available_memory() / 1_048_576
                self?.host.journal.line("diagnostics: memory warning available=\(megabytes) MB")
            }
            event(
                level: .notice, category: .diagnostics, code: "boot",
                message: "diagnostics installed")
            host.incidents().install()
        }

        public func event(
            level: DiagnosticLevel,
            category: DiagnosticCategory,
            code: String,
            message: String,
            fields: [String: String] = [:],
            error: Error? = nil,
            includeStack: Bool = false
        ) {
            var fields = fields
            if let error {
                fields["error"] = String(describing: error)
            }
            if includeStack || level == .error || level == .fault {
                fields["stack"] = currentStack()
            }
            let event = DiagnosticEvent(
                level: level, category: category, code: code,
                message: host.redact(message),
                fields: fields.mapValues { host.redact($0) })
            let line = event.journalLine
            switch level {
            case .debug: log.debug("\(line, privacy: .public)")
            case .info: log.info("\(line, privacy: .public)")
            case .notice: log.notice("\(line, privacy: .public)")
            case .warning: log.warning("\(line, privacy: .public)")
            case .error: log.error("\(line, privacy: .public)")
            case .fault: log.fault("\(line, privacy: .public)")
            }
            if level.persistsToJournal {
                host.journal.appendRedacted(line)
            }
            if level == .error || level == .fault {
                appendException(line)
            }
        }

        public func record(error: Error, category: DiagnosticCategory, code: String, message: String) {
            event(
                level: .error, category: category, code: code, message: message,
                error: error, includeStack: true)
        }

        /// A memory warning in the last minute, for the feed incident lifecycle.
        public func hadRecentMemoryWarning(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
            lastMemoryWarningUptime.map { now - $0 < 60 } ?? false
        }

        public func beginInterval(_ name: StaticString) -> OSSignpostIntervalState {
            signposter.beginInterval(name)
        }

        public func endInterval(_ name: StaticString, _ state: OSSignpostIntervalState) {
            signposter.endInterval(name, state)
        }

        @MainActor
        public func environment(camera: DiagnosticCamera) -> DiagnosticEnvironment {
            let info = Bundle.main.infoDictionary
            return DiagnosticEnvironment(
                product: host.product,
                appVersion: info?["CFBundleShortVersionString"] as? String ?? "0",
                appBuild: info?["CFBundleVersion"] as? String ?? "0",
                osName: "iOS",
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                deviceModel: DiagnosticsDevice.current.hardwareClass,
                cameraFamily: camera.family,
                cameraModel: camera.model,
                phase: camera.phase,
                vpnActive: DiagnosticNetworkFacts.vpnActive(),
                localNetwork: host.localNetwork())
        }

        @MainActor
        public func manualReport(camera: DiagnosticCamera) -> String {
            DiagnosticReport.manualReport(
                environment: environment(camera: camera),
                journal: host.journal.recentLines(),
                exceptions: Self.readLines(Self.exceptionsURL),
                extras: host.incidents().reportExtras() + Self.metricKitExtras(),
                isSafeNetwork: host.isSafeNetwork)
        }

        /// What writing the diagnostics report did.
        public enum ReportWrite: Equatable {
            case written(URL)
            /// The report could not be written; the message reaches the operator.
            case failed(String)
        }

        @MainActor
        public func writeReport(camera: DiagnosticCamera) -> URL? {
            if case .written(let url) = writeReportFile(camera: camera) { return url }
            return nil
        }

        @MainActor
        public func writeReportFile(camera: DiagnosticCamera) -> ReportWrite {
            let env = environment(camera: camera)
            let journal = host.journal.recentLines()
            let exceptions = Self.readLines(Self.exceptionsURL)
            let extras = Self.metricKitExtras() + host.incidents().reportExtras()
            let body = DiagnosticReport.fullReport(
                environment: env, journal: journal, exceptions: exceptions, extras: extras,
                isSafeNetwork: host.isSafeNetwork)
            guard let dir = Self.diagnosticsDirectory else {
                return .failed("No diagnostics storage is available on this iPhone.")
            }
            let name = "report.txt"
            let url = dir.appendingPathComponent(name)
            do {
                try body.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return .failed("The report could not be written: \(error.localizedDescription)")
            }
            event(
                level: .notice, category: .diagnostics, code: "report",
                message: "wrote diagnostic report")
            return .written(url)
        }

        /// What sharing the diagnostics bundle did (A2-64): the report's item, or why it
        /// could not be written, which the app shows instead of failing silently.
        public enum ShareOutcome: Equatable {
            case ready(MonitorDiagnosticsShareItem)
            case failed(String)
        }

        /// Compact paste plus `report.txt` for the system share sheet.
        @MainActor
        public func beginShare(camera: DiagnosticCamera) -> ShareOutcome {
            copyCompactSummaryForTestFlight(camera: camera)
            switch writeReportFile(camera: camera) {
            case .written(let url): return .ready(MonitorDiagnosticsShareItem(url: url))
            case .failed(let message): return .failed(message)
            }
        }

        @MainActor
        public func compactSummary(camera: DiagnosticCamera) -> String {
            DiagnosticReport.compactSummary(
                environment: environment(camera: camera),
                recent: host.journal.recentLines(),
                isSafeNetwork: host.isSafeNetwork)
        }

        @MainActor
        public func copyCompactSummaryForTestFlight(camera: DiagnosticCamera? = nil) {
            guard let camera = camera ?? host.currentCamera() else { return }
            let text = compactSummary(camera: camera)
            lastCompactSummary = text
            UIPasteboard.general.string = text
            event(
                level: .notice, category: .diagnostics, code: "testflight-paste",
                message: "copied compact diagnostics for TestFlight feedback")
            onCopiedForTestFlight?()
        }

        /// MetricKit payloads, delivered on any thread by the platform subscriber.
        private lazy var metricSubscriber = DiagnosticMetricSubscriber { [weak self] kind, payloads in
            self?.receiveMetricKit(kind: kind, payloads: payloads)
        }

        private func receiveMetricKit(kind: String, payloads: [Data]) {
            persistMetricKit(kind: kind, payloads: payloads)
            guard kind == "diagnostic" else { return }
            // Receipt time is not crash time; a collector stack would misidentify
            // this callback as the fault. Original stacks remain in the payload.
            event(
                level: .notice, category: .diagnostics, code: "metrickit",
                message: "MetricKit diagnostic payload received",
                fields: ["payloadCount": String(payloads.count)])
        }

        private func persistMetricKit(kind: String, payloads: [Data]) {
            guard let dir = Self.diagnosticsDirectory else { return }
            let deliveryID = UUID()
            let deliveredAt = Date()
            for (index, data) in payloads.enumerated() {
                let text = host.redact(String(data: data, encoding: .utf8) ?? "")
                let name = FeedIncidentFileNaming.metricKit(
                    kind: kind, deliveredAt: deliveredAt, deliveryID: deliveryID, index: index)
                let url = dir.appendingPathComponent(name)
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
            pruneMetricKit(in: dir)
        }

        private func pruneMetricKit(in dir: URL) {
            let fm = FileManager.default
            let ttl: TimeInterval = 604_800
            let maxFiles = 20
            let maxBytes = 2_097_152
            guard
                var files = try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            else { return }
            files = files.filter { $0.lastPathComponent.hasPrefix("metrickit-") }
            let now = Date()
            for url in files {
                let modified =
                    (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? now
                if now.timeIntervalSince(modified) > ttl {
                    try? fm.removeItem(at: url)
                }
            }
            files = files.filter { fm.fileExists(atPath: $0.path) }
            func fileSize(_ url: URL) -> Int {
                (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
            func fileDate(_ url: URL) -> Date {
                (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
            }
            files.sort { fileDate($0) < fileDate($1) }
            var total = files.reduce(0) { $0 + fileSize($1) }
            while files.count > maxFiles || total > maxBytes, let oldest = files.first {
                total -= fileSize(oldest)
                try? fm.removeItem(at: oldest)
                files.removeFirst()
            }
        }

        private func appendException(_ line: String) {
            guard let url = Self.exceptionsURL else { return }
            let row = Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8)
            if FileManager.default.fileExists(atPath: url.path),
                let handle = try? FileHandle(forWritingTo: url)
            {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: row)
            } else {
                try? row.write(to: url)
            }
            trimExceptions()
        }

        private func trimExceptions() {
            guard let url = Self.exceptionsURL,
                let existing = try? String(contentsOf: url, encoding: .utf8)
            else { return }
            var lines = existing.split(whereSeparator: \.isNewline).map(String.init)
            if lines.count > DiagnosticReport.exceptionCap {
                lines = Array(lines.suffix(DiagnosticReport.exceptionCap))
                try? (lines.joined(separator: "\n") + "\n").write(
                    to: url, atomically: true, encoding: .utf8)
            }
        }

        private func currentStack() -> String {
            host.redact(Thread.callStackSymbols.prefix(24).joined(separator: " | "))
        }

        private nonisolated func recordUncaught(_ exception: NSException) {
            let reason = host.redact(exception.reason ?? "")
            let stack = host.redact(exception.callStackSymbols.joined(separator: " | "))
            let line =
                "fault diagnostics ns-exception name=\(exception.name.rawValue) reason=\(reason) stack=\(stack)"
            host.journal.appendRedacted(line, logNow: true)
            if let url = Self.exceptionsURL {
                let row = Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8)
                if FileManager.default.fileExists(atPath: url.path),
                    let handle = try? FileHandle(forWritingTo: url)
                {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: row)
                } else {
                    try? row.write(to: url)
                }
            }
        }

        public nonisolated static func readLines(_ url: URL?) -> [String] {
            guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
                return []
            }
            return text.split(whereSeparator: \.isNewline).map(String.init)
        }

        public nonisolated static func metricKitExtras() -> [(name: String, body: String)] {
            guard let dir = diagnosticsDirectory else { return [] }
            let files =
                (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.lastPathComponent.hasPrefix("metrickit-") }.compactMap {
                url in
                guard let body = try? String(contentsOf: url, encoding: .utf8), !body.isEmpty else {
                    return nil
                }
                return (url.lastPathComponent, body)
            }
        }

    }

#endif
