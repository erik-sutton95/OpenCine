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

    /// The decoder calls an incident may name: MediaCodec's on Android, VideoToolbox's and the
    /// display layer's on Apple. Kotlin twin: `FeedIncidentExport.decoderCalls`.
    public static let decoderCalls: Set<String> = [
        "createCodec", "configure", "start", "dequeueInput", "getInputBuffer", "fillInput",
        "queueInput", "dequeueOutput", "releaseOutput",
        "createSession", "decodeFrame", "outputCallback", "displayLayer",
    ]

    /// The Apple decoder's error origin (`VideoToolboxDecoder.lastDecodeOrigin`) as a call.
    public static func appleDecoderCall(origin: String) -> String? {
        switch origin {
        case "create": return "createSession"
        case "submit", "sync": return "decodeFrame"
        case "callback": return "outputCallback"
        case "display": return "displayLayer"
        default: return nil
        }
    }

    /// The snapshot the incident opened on: the last one before it, else its first.
    public static func onset(_ bundle: FeedIncidentBundle) -> FeedIncidentSnapshot? {
        bundle.prelude.last ?? bundle.during.first
    }

    /// Coarse, searchable keyframe age. Exact seconds stay in the attachment.
    public static func irapAgeBucket(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "never" }
        if seconds < 1 { return "0-1s" }
        if seconds < 5 { return "1-5s" }
        if seconds < 30 { return "5-30s" }
        return "30s+"
    }

    /// Whether the decoder took what it was given: `idle` (nothing submitted), `rejecting`
    /// (submits, no accepts), `partial` (under 80 % accepted) or `flowing`. Exact rates stay in
    /// the attachment.
    public static func decodeFlow(submitHz: Double, acceptHz: Double) -> String {
        if submitHz < 0.5 { return "idle" }
        if acceptHz < 0.5 { return "rejecting" }
        if acceptHz < submitHz * 0.8 { return "partial" }
        return "flowing"
    }

    /// The call that raised the incident's error class, from the snapshots that carry it.
    public static func decoderCall(_ bundle: FeedIncidentBundle) -> String {
        guard let errorClass = bundle.header.errorClass else { return "none" }
        let candidates = [onset(bundle)].compactMap { $0 } + bundle.during + bundle.prelude.reversed()
        guard
            let call = candidates.first(where: {
                $0.decoder.errorClass == errorClass && $0.decoder.errorCall != nil
            })?.decoder.errorCall
        else { return "none" }
        return decoderCalls.contains(call) ? call : "other"
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
        let opening = onset(bundle)
        // The 1 Hz snapshot opens an incident up to a tick after its first repair.
        let own = bundle.repairs.filter { $0.monotonicAt >= header.startedAtMonotonic - 1.5 }.map {
            $0.closed()
        }
        // The incident's own snapshots: its opening tick and everything recorded while it was open.
        let window =
            bundle.prelude.filter { $0.monotonicNow >= header.startedAtMonotonic } + bundle.during
        // A session drop stops the snapshots, so an app switch inside it shows only as a breadcrumb.
        // One recorded after the incident ended (aftermath collection) is not the incident's.
        let incidentEnd = header.endedAtMonotonic
        let sceneInactive = bundle.breadcrumbs.contains { crumb in
            crumb.kind == .sceneActivity && crumb.detail == "inactive"
                && crumb.monotonicAt >= header.startedAtMonotonic - 1.5
                && incidentEnd.map { crumb.monotonicAt <= $0 } ?? true
        }
        let background: String
        if sceneInactive
            || window.contains(where: { !$0.lifecycle.foreground || !$0.lifecycle.sceneActive })
        {
            background = "yes"
        } else if window.isEmpty {
            background = "unknown"
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
        var envelope = FeedIncidentVendorEnvelope(
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
            decoderCall: decoderCall(bundle),
            keyframeWait: opening.map { $0.decoder.awaitingIrap ? "awaiting" : "none" } ?? "unknown",
            irapAge: opening.map { irapAgeBucket($0.decoder.lastIrapAge) } ?? "unknown",
            decodeFlow: opening.map {
                // Absent observations stay unknown; numeric rates support legacy producers.
                if let observed = $0.rates.observed {
                    guard
                        let submitHz = observed.decodeSubmitHz,
                        let acceptHz = observed.decodeAcceptHz
                    else { return "unknown" }
                    return decodeFlow(submitHz: submitHz, acceptHz: acceptHz)
                }
                return decodeFlow(
                    submitHz: $0.rates.decodeSubmitHz, acceptHz: $0.rates.decodeAcceptHz)
            } ?? "unknown",
            background: background,
            awaitingIrap: awaitingIrap)
        // The snapshot that opened the incident is the prelude's last; a short incident may have
        // no `during` snapshot yet.
        let during = Array(bundle.prelude.suffix(1)) + bundle.during
        let firstError = during.lazy.compactMap(\.decoder.firstError?.status).first { $0 != 0 }
        let lastStatus = during.lazy.reversed().compactMap(\.decoder.lastStatus).first { $0 != 0 }
        envelope.decoderStatus = (firstError ?? lastStatus).map(String.init) ?? "none"
        let codec = during.last?.decoder.codec ?? "unknown"
        envelope.decoderCodec = decoderCodecs.contains(codec) ? codec : "other"
        envelope.watchdogHold =
            during.lazy.reversed().compactMap(\.watchdogGate?.hold).first ?? "none"
        return envelope
    }

    /// The codec names producers report (`MonitorLiveVideoRuntime.incidentCodec`, MediaCodec).
    public static let decoderCodecs: Set<String> = ["avc", "hevc", "unknown"]
}
