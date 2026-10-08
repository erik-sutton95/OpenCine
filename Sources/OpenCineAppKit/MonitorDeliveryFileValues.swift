import Foundation

/// File naming uses actual typed export settings; native container/curve tags arrive as values.
public enum MonitorDeliveryFileNaming {
    public static func filename<Curve: Sendable, Format: Sendable>(original: String,
        configuration: MonitorDeliveryExportConfiguration<Curve, Format>,
        formatExtension: String, transformToken: String? = nil) -> String {
        let stem = (original as NSString).deletingPathExtension
        if configuration.convertLog, let transformToken { return "\(stem).\(transformToken).\(formatExtension)" }
        guard configuration.bakeLUT || configuration.convertLog else { return original }
        return "\(stem).\(formatExtension)"
    }
}
public struct MonitorDeliveryMetadataFacts: Sendable {
    public let filename: String
    public let captureDate: String?
    public let sizeBytes: UInt64?
    public init(filename: String, captureDate: String?, sizeBytes: UInt64?) {
        self.filename = filename; self.captureDate = captureDate; self.sizeBytes = sizeBytes
    }
}
public enum MonitorDeliveryMetadataSummary {
    public static func text(files: [MonitorDeliveryMetadataFacts], formatBytes: (UInt64) -> String) -> String {
        files.map { file in
            let size = file.sizeBytes.map(formatBytes) ?? "unknown size"
            return "\(file.filename) · \(file.captureDate ?? "unknown date") · \(size)"
        }.joined(separator: "\n")
    }
}
/// Shared inclusion decisions. The source retains its exact native metadata schema and values.
public struct MonitorDeliveryMetadataSelection: Equatable, Sendable {
    public let included: Bool
    public let bakedLook: Bool
    public let bakedExposure: Bool
    public let convertedCurve: Bool
    public init<Curve: Sendable, Format: Sendable>(_ configuration: MonitorDeliveryExportConfiguration<Curve, Format>) {
        included = configuration.includeMetadata
        bakedLook = included && !configuration.convertLog && configuration.bakeLUT
        bakedExposure = bakedLook && configuration.bakeLUTExposure
        convertedCurve = included && configuration.convertLog
    }
}
