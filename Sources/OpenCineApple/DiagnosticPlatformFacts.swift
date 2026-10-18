#if os(iOS)
    import Foundation
    import MetricKit
    import OpenCineCore

    /// MetricKit delivery for on-device diagnostics: each payload's JSON by kind, `"metric"` or
    /// `"diagnostic"`. MetricKit calls in from any thread.
    public final class DiagnosticMetricSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
        private let deliver: @Sendable (_ kind: String, _ payloads: [Data]) -> Void

        public init(deliver: @escaping @Sendable (_ kind: String, _ payloads: [Data]) -> Void) {
            self.deliver = deliver
            super.init()
        }

        public func start() {
            MXMetricManager.shared.add(self)
        }

        public func didReceive(_ payloads: [MXMetricPayload]) {
            deliver("metric", payloads.map { $0.jsonRepresentation() })
        }

        public func didReceive(_ payloads: [MXDiagnosticPayload]) {
            deliver("diagnostic", payloads.map { $0.jsonRepresentation() })
        }
    }

    /// Network facts a diagnostic report states.
    public enum DiagnosticNetworkFacts {
        /// A VPN carries this phone's traffic now.
        public static func vpnActive() -> Bool { LocalVPNProbe.isActive() }
    }
#endif
