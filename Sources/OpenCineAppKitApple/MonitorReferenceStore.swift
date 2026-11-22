#if os(iOS)
    import Foundation
    import Observation
    import UIKit

    /// One admitted clean raster and the aspect of the image the operator was matching.
    public struct MonitorReferenceStill: Sendable {
        public let image: CGImage
        public let displayAspect: Double
        public let orientation: UIImage.Orientation

        public init(
            image: CGImage, displayAspect: Double, orientation: UIImage.Orientation = .up
        ) {
            self.image = image
            self.displayAspect = displayAspect
            self.orientation = orientation
        }
    }

    /// An app's single continuity reference. The saved raster and aspect are replaced together.
    @MainActor @Observable
    public final class MonitorReferenceStore {
        public private(set) var saved: MonitorReferenceStill?
        public private(set) var saving = false
        public private(set) var notice: String?
        public var visible = false
        public var mode: Mode = .blend
        public var blend = 0.5
        public var divider = 0.5
        public var referenceOnRight = false

        public enum Mode: String, CaseIterable, Hashable {
            case blend = "Blend"
            case split = "Split"
        }

        @ObservationIgnored private let file: URL
        private struct Record: Codable {
            let jpeg: Data
            let aspect: Double
        }

        /// Use the app's private Application Support directory, with a separate directory for backup policy.
        public init(
            directory: URL = .applicationSupportDirectory.appending(path: "ContinuityReference")
        ) {
            file = directory.appending(path: "reference-v1.plist")
            if let bytes = try? Data(contentsOf: file),
                let record = try? PropertyListDecoder().decode(Record.self, from: bytes)
            {
                saved = Self.decode(record)
            }
        }

        /// Capture and replace once. Failures leave the saved image and its visibility available.
        public func save(_ capture: @MainActor () async -> MonitorReferenceStill?) async {
            guard !saving else { return }
            saving = true
            defer { saving = false }
            notice = nil
            guard let still = await capture(), !Task.isCancelled else {
                if !Task.isCancelled {
                    notice =
                        "The current frame is unavailable. Try again when the picture is ready."
                }
                return
            }
            let destination = file
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Self.write(still, to: destination)
                }.value
                saved = result
            } catch {
                notice = "The reference could not be saved. Try again."
            }
        }

        /// Clear the capture status after it is displayed.
        public func dismissNotice() { notice = nil }

        private nonisolated static func decode(_ record: Record) -> MonitorReferenceStill? {
            guard record.aspect.isFinite, record.aspect > 0,
                let raster = UIImage(data: record.jpeg)?.cgImage
            else { return nil }
            return .init(image: raster, displayAspect: record.aspect)
        }

        private nonisolated static func write(_ still: MonitorReferenceStill, to file: URL) throws
            -> MonitorReferenceStill
        {
            let upright = UIImage(cgImage: still.image, scale: 1, orientation: still.orientation)
            let scale = min(1, 1600 / max(upright.size.width, upright.size.height))
            let size = CGSize(
                width: (upright.size.width * scale).rounded(),
                height: (upright.size.height * scale).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            format.preferredRange = .standard
            let jpeg = UIGraphicsImageRenderer(size: size, format: format)
                .jpegData(withCompressionQuality: 0.92) { _ in
                    upright.draw(in: CGRect(origin: .zero, size: size))
                }
            let record = Record(jpeg: jpeg, aspect: still.displayAspect)
            guard let saved = decode(record) else { throw CocoaError(.fileWriteUnknown) }
            var directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try directory.setResourceValues(resources)
            try PropertyListEncoder().encode(record).write(to: file, options: .atomic)
            return saved
        }
    }
#endif
