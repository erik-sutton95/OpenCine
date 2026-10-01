import Foundation

/// The outcome of a multi-clip Frame.io delivery.
///
/// Partial results are first class: a batch that uploads some clips and fails others reports
/// both, plus side effects that failed without failing the upload (metadata sidecar, temporary
/// export cleanup, upload history).
public struct FrameioDeliveryReport: Equatable, Sendable {
    public var uploaded = 0
    /// Already delivered according to history, or not eligible (the app's `prepare` said so).
    public var skipped = 0
    public var failed = 0
    public var metadataFailures = 0
    public var cleanupFailures = 0
    public var historyFailures = 0
    /// The first failure's operator-facing message, in item order.
    public var firstFailureMessage: String?

    public init() {}

    mutating func fail(_ message: String) {
        failed += 1
        if firstFailureMessage == nil { firstFailureMessage = message }
    }
}

/// App-owned record of confirmed uploads keyed by a stable clip identity (never a filename,
/// project or cloud identifier).
public protocol FrameioUploadHistory: Sendable {
    func wasUploaded(_ identity: String) throws -> Bool
    /// Durably records a confirmed upload; false means the store rejected the write.
    func recordUploaded(_ identity: String) throws -> Bool
}

/// One clip's upload result.
public enum FrameioItemUpload: Equatable, Sendable {
    case uploaded
    /// The clip uploaded but its optional metadata sidecar did not.
    case uploadedWithoutMetadata
}

/// Runs one delivery batch: for each item, consult history, prepare (export, bake), upload,
/// always release what was prepared, then record history.
public enum FrameioDelivery {
    /// - Parameters:
    ///   - history: pass `nil` to upload everything (no history, or a forced re-upload).
    ///   - identity: the item's stable history key; `nil` skips history for that item.
    ///   - prepare: returns the upload source, or `nil` when the item is not eligible (skipped).
    ///   - upload: uploads a prepared item.
    ///   - release: removes a temporary export; a failure counts as a cleanup failure.
    /// - Throws: only `CancellationError`. Every other error is reported per item.
    public static func run<Item, Prepared>(
        _ items: [Item],
        history: (any FrameioUploadHistory)? = nil,
        identity: (Item) -> String? = { _ in nil },
        prepare: (Item) async throws -> Prepared?,
        upload: (Item, Prepared) async throws -> FrameioItemUpload,
        release: (Prepared) async throws -> Void = { _ in }
    ) async throws -> FrameioDeliveryReport {
        var report = FrameioDeliveryReport()
        for item in items {
            try Task.checkCancellation()
            let key = history == nil ? nil : identity(item)
            if let history, let key {
                do {
                    if try history.wasUploaded(key) {
                        report.skipped += 1
                        continue
                    }
                } catch {
                    report.historyFailures += 1
                    report.fail("Couldn't read the private Frame.io upload history.")
                    continue
                }
            }

            let prepared: Prepared?
            do {
                prepared = try await prepare(item)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                report.fail(error.localizedDescription)
                continue
            }
            guard let prepared else {
                report.skipped += 1
                continue
            }

            let result: Result<FrameioItemUpload, any Error>
            do {
                result = .success(try await upload(item, prepared))
            } catch {
                result = .failure(error)
            }
            // Release even after a failed or cancelled upload; a leaked export is reported.
            do {
                try await release(prepared)
            } catch {
                report.cleanupFailures += 1
            }

            switch result {
            case .failure(let error):
                if error is CancellationError { throw error }
                report.fail(error.localizedDescription)
            case .success(let upload):
                report.uploaded += 1
                if upload == .uploadedWithoutMetadata { report.metadataFailures += 1 }
                if let history, let key, (try? history.recordUploaded(key)) != true {
                    report.historyFailures += 1
                }
            }
        }
        return report
    }
}
