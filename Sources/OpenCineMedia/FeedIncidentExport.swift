import Foundation

/// Journal-independent incident text and vendor-neutral envelope.
public enum FeedIncidentExport: Sendable {
    /// `product` heads the listing (the host app's name).
    public static func extras(from bundles: [FeedIncidentBundle], product: String) -> [(
        name: String, body: String
    )] {
        var extras: [(name: String, body: String)] = []
        extras.append(("incidents.txt", text(from: bundles, product: product)))
        for bundle in bundles {
            if let data = try? FeedIncidentCoding.encoder().encode(bundle),
                let body = String(data: data, encoding: .utf8)
            {
                extras.append(
                    (
                        FeedIncidentFileNaming.incident(id: bundle.header.incidentID),
                        PrivacyRedactor.redact(body)
                    ))
            }
        }
        return extras
    }

    public static func text(from bundles: [FeedIncidentBundle], product: String) -> String {
        var lines = [
            "\(product) feed incidents (typed snapshots, no journal)",
            "count=\(bundles.count) schema=\(FeedIncidentSchema.version)",
        ]
        for bundle in bundles {
            let header = bundle.header
            lines.append("---")
            lines.append(
                "id=\(header.incidentID) kind=\(header.kind.rawValue) stage=\(header.failingStage.rawValue) outcome=\(header.outcome.rawValue)"
            )
            lines.append(
                "session=\(header.sessionID) started=\(ISO8601DateFormatter().string(from: header.startedAtWallClock)) gap=\(String(format: "%.3f", header.worstGapSeconds))s"
            )
            lines.append(
                "release=\(header.appVersion)(\(header.appBuild)) rev=\(header.sourceRevision) identity=\(header.resolvedBuildIdentity) source=\(header.resolvedTestSource.rawValue) os=\(header.osName) \(header.osVersion) hw=\(header.hardwareClass)"
            )
            lines.append(
                "camera=\(header.cameraFamily) fw=\(header.cameraFirmware ?? "none") decoderGen=\(header.decoderGeneration) socketGen=\(header.socketGeneration) assist=\(header.assistState)"
            )
            if let errorClass = header.errorClass {
                lines.append("errorClass=\(errorClass)")
            }
            lines.append(
                "snapshots prelude=\(bundle.prelude.count) during=\(bundle.during.count) aftermath=\(bundle.aftermath.count) repairs=\(bundle.repairs.count) breadcrumbs=\(bundle.breadcrumbs.count) evictions=\(header.evictions) healthySeconds=\(String(format: "%.1f", header.healthyExposureSeconds))"
            )
            if header.processInterrupted {
                lines.append("process=interrupted")
            }
        }
        return PrivacyRedactor.redact(lines.joined(separator: "\n"))
    }

    /// Coarse, searchable picture-gap tag. Exact seconds stay in extras.
    public static func gapBucket(_ seconds: TimeInterval) -> String {
        let edges: [TimeInterval] = [2, 5, 10, 20, 40, 120]
        guard let upper = edges.first(where: { seconds < $0 }) else { return "120s+" }
        let lower = edges.last(where: { $0 < upper }) ?? 0
        return "\(Int(lower))-\(Int(upper))s"
    }

    public static func envelope(from bundle: FeedIncidentBundle) -> FeedIncidentVendorEnvelope {
        let header = bundle.header
        // The 1 Hz snapshot opens an incident up to a tick after its first repair.
        let own = bundle.repairs.filter { $0.monotonicAt >= header.startedAtMonotonic - 1.5 }.map {
            $0.closed()
        }
        // The incident's own snapshots: its opening tick and everything recorded while it was open.
        let window =
            bundle.prelude.filter { $0.monotonicNow >= header.startedAtMonotonic - 1.5 } + bundle.during
        let background: String
        if window.isEmpty {
            background = "unknown"
        } else if window.contains(where: { !$0.lifecycle.foreground || !$0.lifecycle.sceneActive }) {
            background = "yes"
        } else {
            background = "no"
        }
        let awaitingIrap = window.last.map { $0.decoder.awaitingIrap ? "yes" : "no" } ?? "unknown"
        let grouping = FeedIncidentGrouping(
            schemaVersion: header.schemaVersion,
            failingStage: header.failingStage.rawValue,
            errorClass: header.errorClass ?? "none",
            outcome: header.outcome.rawValue,
            release: "\(header.appVersion)(\(header.appBuild))",
            os: "\(header.osName) \(header.osVersion)",
            hardwareClass: header.hardwareClass,
            cameraFirmware: header.cameraFirmware ?? "none",
            assistState: header.assistState)
        return FeedIncidentVendorEnvelope(
            schemaVersion: header.schemaVersion,
            eventName: "feed.incident",
            grouping: grouping,
            incidentID: header.incidentID,
            sessionID: header.sessionID,
            kind: header.kind.rawValue,
            worstGapSeconds: header.worstGapSeconds,
            healthyExposureSeconds: header.healthyExposureSeconds,
            decoderGeneration: header.decoderGeneration,
            socketGeneration: header.socketGeneration,
            testSource: header.resolvedTestSource.rawValue,
            buildIdentity: header.resolvedBuildIdentity,
            trigger: own.lazy.compactMap(\.reason).first ?? "none",
            // A first-picture resend inside an endpoint/rejoin repair is on the
            // timeline, but the rung that opened the new session gets the credit.
            recoveredBy: header.outcome == .recovered
                ? own.last(where: { $0.reason != FeedRepairRecord.firstPictureReason })?.action
                    ?? "none"
                : "none",
            background: background,
            awaitingIrap: awaitingIrap)
    }
}
