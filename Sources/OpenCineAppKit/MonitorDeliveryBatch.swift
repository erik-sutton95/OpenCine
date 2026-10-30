import Foundation
import OpenCineCore

@MainActor private final class MonitorDeliveryStep {
    var active = true
    var latestProgress: MonitorDeliveryBatchProgress?
}

public struct MonitorDeliveryCachedOriginals<Record: Sendable>: Sendable {
    public let ready: [Record]
    public let uncached: Int
    /// Uncached records whose acquisition ended because the camera stopped answering.
    public let cameraStopped: Int
    public init(ready: [Record], uncached: Int, cameraStopped: Int = 0) {
        self.ready = ready
        self.uncached = uncached
        self.cameraStopped = cameraStopped
    }
}

@available(macOS 14, *) extension MonitorDeliveryModel {
    /// Cache-only part of the same admitted run. Missing receipts remain explicit and ordered.
    public static func cacheOriginals<Record: Sendable>(
        records: [Record], destination: MonitorDeliveryDestination,
        admission: MonitorDeliveryAdmission, originals: MonitorDeliveryOriginalService<Record>,
        filename: @escaping @MainActor (Record) -> String, uploadCaption: String? = nil,
        sleep: @escaping @MainActor (Duration) async throws -> Void = hostSleep(for:),
        progress: @escaping @MainActor (MonitorDeliveryBatchProgress) -> Void
    ) async -> MonitorDeliveryCachedOriginals<Record>? {
        func accepts() -> Bool { admission.isCurrent() }
        var toCache: [Record] = []
        for record in records {
            guard accepts() else { return nil }
            let available = originals.available(record)
            guard accepts() else { return nil }
            if !available { toCache.append(record) }
        }
        var uncached = 0
        var cameraStopped = 0
        for (index, record) in toCache.enumerated() {
            guard accepts() else { return nil }
            let gate = MonitorDeliveryStep()
            var value = MonitorDeliveryBatchProgress(
                destination: destination, totalClips: toCache.count,
                clipIndex: index + 1, clipFraction: 0, isCaching: true,
                filename: filename(record), uploadCaption: uploadCaption)
            value.stage = .caching
            progress(value)
            guard accepts() else { return nil }
            let mirror = Task { @MainActor in
                while gate.active && accepts() {
                    do { try await sleep(.milliseconds(200)) } catch { return }
                    guard gate.active, accepts() else { return }
                    let fraction = originals.progress(record)
                    guard gate.active, accepts(), let fraction else { continue }
                    value.clipFraction = fraction
                    progress(value)
                }
            }
            await originals.acquire(record)
            gate.active = false
            mirror.cancel()
            guard accepts() else { return nil }
            let available = originals.available(record)
            guard accepts() else { return nil }
            if !available {
                uncached += 1
                if originals.cameraStoppedResponding(record) { cameraStopped += 1 }
            }
        }
        var ready: [Record] = []
        for record in records {
            guard accepts() else { return nil }
            let available = originals.available(record)
            guard accepts() else { return nil }
            if available { ready.append(record) }
        }
        return .init(ready: ready, uncached: uncached, cameraStopped: cameraStopped)
    }

    /// Remote delivery from the camera network needs every original first. This caches them as a
    /// captured run of this owner (same chrome and cancel) and throws unless all are cached, so a
    /// caller never leaves the camera network with clips still on the camera (A2-05). A caller
    /// that tracks an earlier captured run passes it as `outgoing`; it is joined first.
    public func cacheBeforeInternetHop<Record: Sendable>(
        records: [Record], originals: MonitorDeliveryOriginalService<Record>,
        after outgoing: MonitorDeliveryRunHandle? = nil,
        source: MonitorDeliveryAdmission, filename: @escaping @MainActor (Record) -> String,
        completion: Outcome, uploadCaption: String? = nil,
        progress: @escaping @MainActor (MonitorDeliveryBatchProgress) -> Progress,
        onStarted: (MonitorDeliveryRunHandle) -> Void = { _ in }
    ) async throws {
        let run = beginCaptured { report, admission in
            await outgoing?.cancelAndJoin()
            _ = await Self.cacheOriginals(
                records: records, destination: .remoteUpload,
                admission: .init { admission.isCurrent() && source.isCurrent() },
                originals: originals, filename: filename, uploadCaption: uploadCaption
            ) { report(progress($0)) }
            return .init(completion)
        }
        guard let run else { throw CancellationError() }
        onStarted(run)
        await run.awaitEnteredCleanup()
        guard source.isCurrent() else { throw CancellationError() }
        // The cache itself is the truth: a cancelled or superseded run leaves clips uncached.
        let missing = records.filter { !originals.available($0) }
        if missing.contains(where: originals.cameraStoppedResponding) {
            throw MonitorDeliveryCacheError.cameraStoppedResponding(missing.count)
        }
        if !missing.isEmpty { throw MonitorDeliveryCacheError.uncached(missing.count) }
    }

    /// Ordering and progress use this existing delivery run. Original bytes, native preparation,
    /// OS transactions and route leases remain in their existing bounded owners. Every app runs
    /// the one `MonitorDeliveryBatchPolicy`.
    public static func runBatch<Record: Sendable, Artifact: Sendable, Lease: Sendable>(
        records: [Record], destination: MonitorDeliveryDestination,
        action: MonitorDeliveryPostExportAction,
        admission: MonitorDeliveryAdmission, originals: MonitorDeliveryOriginalService<Record>,
        exporter: MonitorDeliveryExportService<Record, Artifact>,
        share: (@MainActor ([Artifact]) throws -> MonitorDeliveryShareFiles<Artifact>)?,
        photos: MonitorDeliveryPhotosService<Artifact>?,
        photosAuthorization: MonitorDeliveryPhotosAuthorizationService? = nil,
        upload: MonitorDeliveryUploadService<Artifact>? = nil,
        uploadHistory: MonitorDeliveryUploadHistory<Record>? = nil, reupload: Bool = false,
        internet: MonitorDeliveryInternetService<Lease>? = nil, lease initialLease: Lease? = nil,
        filename: @escaping @MainActor (Record) -> String,
        artifactFilename: @escaping @MainActor (Artifact) -> String? = { _ in nil },
        metadata: @escaping @MainActor ([Record]) -> String? = { _ in nil },
        noPrepared: @escaping @MainActor ([Record]) -> String? = { _ in nil },
        sleep: @escaping @MainActor (Duration) async throws -> Void = hostSleep(for:),
        progress: @escaping @MainActor (MonitorDeliveryBatchProgress) -> Void
    ) async -> MonitorDeliveryBatchOutcome<Artifact> {
        typealias Policy = MonitorDeliveryBatchPolicy
        var lease = initialLease
        var retainedArtifacts: [Artifact] = []
        @MainActor func execute() async -> MonitorDeliveryBatchOutcome<Artifact> {
            func cancelled() -> MonitorDeliveryBatchOutcome<Artifact> {
                .failed(message: "Cancelled.")
            }
            func accepts() -> Bool { admission.isCurrent() }
            if let lease {
                guard let internet, accepts(), internet.owns(lease),
                    accepts()
                else { return cancelled() }
            }
            if destination == .nativeShare, action == .saveToPhotos, let photosAuthorization {
                guard accepts() else { return cancelled() }
                let pending = photosAuthorization.isPending()
                guard accepts() else { return cancelled() }
                if pending {
                    var value = MonitorDeliveryBatchProgress(
                        destination: destination, totalClips: max(records.count, 1),
                        clipIndex: 1, clipFraction: 0)
                    value.stage = .awaitingPhotosAccess
                    progress(value)
                    guard accepts() else { return cancelled() }
                }
                do { try await photosAuthorization.authorize() } catch {
                    guard accepts(), !(error is CancellationError) else { return cancelled() }
                    return .failed(message: error.localizedDescription)
                }
                guard accepts() else { return cancelled() }
            }
            // Already uploaded records are skipped before any cache or export work (A2-53).
            var deliverable: [Record] = []
            var alreadyUploaded = 0
            for record in records {
                guard accepts() else { return cancelled() }
                if destination == .remoteUpload, !reupload, let uploadHistory,
                    uploadHistory.wasUploaded(record)
                {
                    alreadyUploaded += 1
                } else {
                    deliverable.append(record)
                }
            }
            guard accepts() else { return cancelled() }
            if deliverable.isEmpty, alreadyUploaded > 0 {
                return .uploaded(summary: "\(alreadyUploaded) skipped")
            }
            guard
                let cached = await cacheOriginals(
                    records: deliverable, destination: destination, admission: admission,
                    originals: originals, filename: filename,
                    uploadCaption: upload?.progressCaption,
                    sleep: sleep, progress: progress)
            else { return cancelled() }
            let ready = cached.ready
            let uncached = cached.uncached
            guard !ready.isEmpty else {
                let message =
                    cached.cameraStopped > 0
                    ? Policy.cameraStoppedResponding(uncached)
                    : uncached > 0 ? Policy.cacheFailure(uncached) : Policy.emptySelection
                return .failed(message: message)
            }
            if destination == .remoteUpload {
                guard upload != nil else { return .failed(message: "Upload is unavailable.") }
                if let internet {
                    guard accepts() else { return cancelled() }
                    let needsHop = internet.needsHop()
                    guard accepts() else { return cancelled() }
                    if needsHop {
                        guard let next = lease ?? internet.begin() else {
                            return .failed(message: Policy.internetFailure)
                        }
                        lease = next
                        guard accepts(), internet.owns(next), accepts() else { return cancelled() }
                        var value = MonitorDeliveryBatchProgress(
                            destination: destination, totalClips: ready.count,
                            clipIndex: 1, clipFraction: 0, isSwitchingNetworks: true,
                            uploadCaption: upload?.progressCaption)
                        value.stage = .switchingNetworks
                        progress(value)
                        guard accepts() else { return cancelled() }
                        let online = await internet.wait(next)
                        guard accepts(), internet.owns(next), accepts() else { return cancelled() }
                        value.isSwitchingNetworks = false
                        value.stage = .preparing
                        progress(value)
                        guard accepts() else { return cancelled() }
                        if !online { return .failed(message: Policy.internetFailure) }
                    }
                }
            }
            var prepared: [Artifact] = []
            var uploaded = 0
            var skipped = alreadyUploaded
            var failed = 0
            var firstFailure: String?
            for (index, record) in ready.enumerated() {
                guard accepts() else { return cancelled() }
                let gate = MonitorDeliveryStep()
                let value = MonitorDeliveryBatchProgress(
                    destination: destination, totalClips: ready.count,
                    clipIndex: index + 1, clipFraction: 0, filename: filename(record),
                    uploadCaption: upload?.progressCaption)
                progress(value)
                guard accepts() else { return cancelled() }
                do {
                    let artifact: Artifact?
                    if let original = exporter.original?(record) {
                        // A still travels as its cached original: borrowed, never released.
                        artifact = original
                    } else {
                        artifact = try await exporter.prepare(record) { fraction in
                            guard gate.active, accepts() else { return }
                            var next = value
                            next.stage = .exporting
                            next.clipFraction =
                                destination == .remoteUpload ? fraction * 0.45 : fraction
                            gate.latestProgress = next
                            progress(next)
                        }
                        if let artifact { retainedArtifacts.append(artifact) }
                    }
                    gate.active = false
                    guard accepts() else { return cancelled() }
                    guard let artifact else {
                        skipped += 1
                        continue
                    }
                    if destination == .remoteUpload, let upload {
                        let uploadGate = MonitorDeliveryStep()
                        defer { uploadGate.active = false }
                        try await upload.upload(artifact) { fraction in
                            guard uploadGate.active, accepts() else { return }
                            var next = value
                            next.stage = .uploading
                            next.clipFraction = 0.45 + fraction * 0.55
                            progress(next)
                        }
                        guard accepts() else { return cancelled() }
                        uploaded += 1
                        uploadHistory?.recordUploaded(record)
                    } else {
                        prepared.append(artifact)
                        var completed = gate.latestProgress ?? value
                        completed.clipFraction = 1
                        progress(completed)
                    }
                } catch {
                    gate.active = false
                    guard accepts(), !(error is CancellationError) else { return cancelled() }
                    failed += 1
                    if firstFailure == nil { firstFailure = error.localizedDescription }
                }
            }
            guard accepts() else { return cancelled() }
            if destination == .remoteUpload {
                if ready.count == 1, let firstFailure { return .failed(message: firstFailure) }
                var parts: [String] = []
                if uploaded > 0 { parts.append("\(uploaded) uploaded") }
                if skipped > 0 { parts.append("\(skipped) skipped") }
                if uncached > 0 { parts.append("\(uncached) not cached") }
                if failed > 0 { parts.append("\(failed) failed") }
                let message = parts.joined(separator: ", ")
                if failed > 0 { return .failed(message: message) }
                return .uploaded(summary: message.isEmpty ? "Nothing to upload." : message)
            }
            guard !prepared.isEmpty else {
                return .failed(message: firstFailure ?? noPrepared(ready) ?? Policy.emptySelection)
            }
            do {
                if action == .saveToPhotos {
                    guard let photos else {
                        return .failed(message: "Saving to Photos is unavailable.")
                    }
                    var saved = 0
                    var rejected = 0
                    for (index, artifact) in prepared.enumerated() {
                        guard accepts() else { return cancelled() }
                        var value = MonitorDeliveryBatchProgress(
                            destination: destination, totalClips: prepared.count,
                            clipIndex: index + 1, clipFraction: 1,
                            filename: artifactFilename(artifact))
                        value.stage = .saving
                        progress(value)
                        guard accepts() else { return cancelled() }
                        do {
                            let accepted = try await photos.save(artifact)
                            guard accepts() else { return cancelled() }
                            if accepted { saved += 1 } else { rejected += 1 }
                        } catch {
                            guard accepts(), !(error is CancellationError) else {
                                return cancelled()
                            }
                            rejected += 1
                        }
                    }
                    guard accepts() else { return cancelled() }
                    if let failure = Policy.photosFailure(saved: saved, failed: rejected) {
                        return .failed(message: failure)
                    }
                    let count = saved
                    guard accepts() else { return cancelled() }
                    return .savedToPhotos(count: count)
                }
                guard let share else { return .failed(message: "Sharing is unavailable.") }
                let staged = try share(prepared)
                // A returned staging lease must reach the existing run even when a native callback
                // replaced it. MonitorDeliveryModel then releases only that explicit old lease.
                var text: String?
                if accepts() {
                    let note = Policy.nativeSummary(
                        .init(
                            prepared: prepared.count, uploaded: uploaded,
                            skipped: skipped, failed: failed, uncached: uncached))
                    let originalText = accepts() ? metadata(ready) : nil
                    if let note {
                        let combined = [note, originalText].compactMap { $0 }.filter { !$0.isEmpty }
                            .joined(separator: "\n")
                        text = combined.isEmpty ? nil : combined
                    } else {
                        text = originalText
                    }
                }
                return .share(
                    urls: staged.urls, metadataText: text, stagingCleanupURL: staged.cleanup)
            } catch {
                guard accepts(), !(error is CancellationError) else { return cancelled() }
                return .failed(message: error.localizedDescription)
            }
        }
        let outcome = await execute()
        let enteredArtifacts = retainedArtifacts
        retainedArtifacts.removeAll()
        let enteredLease = lease
        lease = nil
        for artifact in enteredArtifacts { await exporter.release(artifact) }
        if let enteredLease, let internet { await internet.restoreEntered(enteredLease) }
        return outcome
    }
}
