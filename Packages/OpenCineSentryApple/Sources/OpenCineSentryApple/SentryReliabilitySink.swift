#if os(iOS)
    import Foundation
    import OpenCineAppKit
    // `SentrySDK.metrics` is a stored static the SDK does not mark concurrency-safe.
    @preconcurrency import Sentry

    /// OpenCine's reporting runtime on the Sentry SDK: the SDK options, the runtime's calls, and the
    /// privacy rules applied to every event and breadcrumb the SDK sends (crashes included).
    /// Optional adapter: its own package (the only OpenCine code that links a third-party
    /// package), and no OpenCine module imports it. The app passes its host values and the `ReliabilityReportingURLProtocol`
    /// subclass that names its forwarder. Moved from the apps' `SentryReliabilitySink.swift`.
    public final class SentryReliabilitySink: ReliabilityReportingSink, @unchecked Sendable {
        private let host: DiagnosticsHost
        private let consent: ReliabilityReportingConsent
        private let privacy: ReliabilityReportingPrivacy
        private let urlProtocol: ReliabilityReportingURLProtocol.Type
        /// The SDK's dedicated session, kept while the SDK runs. Main thread.
        private var sdkSession: URLSession?

        public init(
            host: DiagnosticsHost, consent: ReliabilityReportingConsent,
            urlProtocol: ReliabilityReportingURLProtocol.Type
        ) {
            self.host = host
            self.consent = consent
            privacy = ReliabilityReportingPrivacy(redact: host.redact)
            self.urlProtocol = urlProtocol
        }

        public var isEnabled: Bool { SentrySDK.isEnabled }

        public func start(dsn: String, cacheRoot: URL) {
            let session = urlProtocol.makeSDKSession()
            sdkSession = session
            SentrySDK.start(
                options: makeOptions(dsn: dsn, urlSession: session, cacheRoot: cacheRoot))
            // Crash reports and metrics carry the anonymous install id through the scope.
            SentrySDK.setUser(Self.user(consent.installID))
        }

        public func close() {
            SentrySDK.close()
            sdkSession = nil
        }

        public func flush(timeout: TimeInterval) {
            SentrySDK.flush(timeout: timeout)
        }

        public func addBreadcrumb(category: String, message: String, data: [String: String]?) {
            let breadcrumb = Breadcrumb(level: .info, category: category)
            breadcrumb.message = message
            breadcrumb.data = data
            SentrySDK.addBreadcrumb(breadcrumb)
        }

        public func setTags(_ tags: [String: String]) {
            SentrySDK.configureScope { scope in
                for (key, value) in tags { scope.setTag(value: value, key: key) }
            }
        }

        /// The event's own tags already win over the scope's when the SDK merges them, so the
        /// capture scope only swaps the attachment; tags set on it would reach scope observers.
        public func capture(_ event: ReliabilityEvent, attachment: Data, attachmentName: String) {
            SentrySDK.capture(event: Self.event(event)) { scope in
                scope.clearAttachments()
                scope.addAttachment(
                    Attachment(
                        data: attachment, filename: attachmentName, contentType: "application/json")
                )
            }
        }

        public func record(_ metric: ReliabilityMetric) {
            SentrySDK.metrics.distribution(
                key: metric.name, value: metric.value,
                unit: metric.unit.flatMap(SentryUnit.init(rawValue:)),
                attributes: metric.attributes)
        }

        /// The SDK user: the anonymous install id only, or none.
        static func user(_ installID: String?) -> User? {
            installID.map { User(userId: $0) }
        }

        public func makeOptions(dsn: String, urlSession: URLSession, cacheRoot: URL) -> Options {
            let options = Options()
            options.dsn = dsn
            options.releaseName = host.release()
            // Cocoa overwrites event.dist when this option is set. Queued reports
            // retain their original build; native events use the SDK bundle fallback.
            options.environment = host.environment
            options.urlSession = urlSession
            options.maxCacheItems = 30
            options.maxAttachmentSize = 256 * 1_024
            options.cacheDirectoryPath = cacheRoot.path
            options.sendDefaultPii = false
            options.enableSwizzling = false
            options.enableNetworkBreadcrumbs = false
            options.enableNetworkTracking = false
            options.enableAutoSessionTracking = false
            options.enableAutoBreadcrumbTracking = false
            options.enableAutoPerformanceTracing = false
            options.enableCaptureFailedRequests = false
            options.enableFileIOTracing = false
            options.enableCoreDataTracing = false
            options.enableMetricKit = false
            options.enableMetricKitRawPayload = false
            options.attachScreenshot = false
            options.attachStacktrace = false
            options.attachViewHierarchy = false
            options.reportAccessibilityIdentifier = false
            options.enableUserInteractionTracing = false
            options.enableUIViewControllerTracing = false
            options.enableTimeToFullDisplayTracing = false
            options.enablePersistingTracesWhenCrashing = false
            options.enableLogs = false
            options.enableMemoryIntrospection = false
            options.tracesSampleRate = 0
            options.tracesSampler = nil
            options.shutdownTimeInterval = 0
            options.enableCrashHandler = true
            options.enableAppHangTracking = true
            options.enableWatchdogTerminationTracking = host.tracksWatchdogTerminations
            options.sessionReplay.sessionSampleRate = 0
            options.sessionReplay.onErrorSampleRate = 0
            options.maxBreadcrumbs = 32
            let privacy = privacy
            let consent = consent
            options.beforeBreadcrumb = { privacy.scrubBreadcrumb($0) }
            options.beforeSend = { event in
                guard consent.isOptedIn else { return nil }
                // Fatal/watchdog events from a prior run already carry persisted
                // tags; Cocoa skips applyToEvent for isFatalEvent. Never fill
                // current-run origin onto missing tags.
                let scrubbed = privacy.scrub(event)
                scrubbed.user = Self.user(consent.installID)
                return scrubbed
            }
            // Only the shared metrics leave the phone, and only under consent.
            options.beforeSendMetric = { metric in
                consent.isOptedIn
                    && ReliabilityReportingPrivacy.metricAllowlist.contains(metric.name)
                    ? metric : nil
            }
            return options
        }

        /// The typed event as the SDK's. A scrubbed event keeps no breadcrumbs of the SDK's scope.
        public static func event(_ event: ReliabilityEvent) -> Event {
            let level: SentryLevel =
                switch event.level {
                case .info: .info
                case .warning: .warning
                case .error: .error
                }
            let sentryEvent = Event(level: level)
            sentryEvent.eventId = SentryId(uuidString: event.eventID)
            sentryEvent.timestamp = event.timestamp
            sentryEvent.releaseName = event.release
            sentryEvent.dist = event.dist
            sentryEvent.message = SentryMessage(formatted: event.message)
            sentryEvent.fingerprint = event.fingerprint
            sentryEvent.tags = event.tags
            sentryEvent.extra = event.extra
            sentryEvent.context = event.context
            if !event.attachesRecentBreadcrumbs { sentryEvent.breadcrumbs = [] }
            return sentryEvent
        }

        /// Compatibility for callers that explicitly manage their own scope.
        /// Capture keeps provenance on the event and does not call this helper.
        @available(*, deprecated, message: "Keep original tags on the event passed to capture.")
        public static func applyOriginalTags(_ tags: [String: String]?, to scope: Scope) {
            guard let tags else { return }
            for (key, value) in tags {
                scope.setTag(value: value, key: key)
            }
        }
    }

    extension ReliabilityReportingPrivacy {
        public func scrubBreadcrumb(_ breadcrumb: Breadcrumb) -> Breadcrumb? {
            guard Self.keepsBreadcrumb(category: breadcrumb.category, message: breadcrumb.message)
            else { return nil }
            breadcrumb.data = Self.breadcrumbData(breadcrumb.data)
            return breadcrumb
        }

        public func scrub(_ event: Event) -> Event {
            event.user = nil
            event.request = nil
            event.breadcrumbs = Array(
                (event.breadcrumbs ?? []).compactMap(scrubBreadcrumb).suffix(32))
            event.serverName = nil
            event.transaction = nil
            if let formatted = event.message?.formatted {
                event.message = SentryMessage(
                    formatted: message(formatted, fingerprint: event.fingerprint))
            }
            if let tags = event.tags { event.tags = self.tags(tags) }
            if let extra = event.extra { event.extra = Self.extra(extra) }
            if let context = event.context { event.context = Self.context(context) }
            if let exceptions = event.exceptions {
                for exception in exceptions {
                    // Exception reasons can contain arbitrary user/application data. Preserve
                    // type, mechanism, symbolication and the SDK's own lifecycle text only.
                    if let value = exception.value { exception.value = Self.exceptionValue(value) }
                    scrub(frames: exception.stacktrace?.frames)
                }
            }
            if let threads = event.threads {
                for thread in threads {
                    scrub(frames: thread.stacktrace?.frames)
                }
            }
            scrub(frames: event.stacktrace?.frames)
            return event
        }

        private func scrub(frames: [Frame]?) {
            guard let frames else { return }
            for frame in frames {
                frame.vars = nil
                frame.contextLine = nil
                frame.preContext = nil
                frame.postContext = nil
                if let file = frame.fileName {
                    frame.fileName = redact(file)
                }
                if let symbol = frame.function {
                    frame.function = redact(symbol)
                }
            }
        }
    }

    #if DEBUG
        extension ReliabilityReportingVerification {
            /// The verification harness (`OPV_RELIABILITY_VERIFY`) over the Sentry SDK.
            public init(
                sentry reporting: ReliabilityReporting,
                isActive: @escaping @MainActor @Sendable () -> Bool
            ) {
                self.init(
                    reporting: reporting, sdkEnabled: { SentrySDK.isEnabled },
                    crash: { SentrySDK.crash() }, isActive: isActive)
            }
        }
    #endif
#endif
