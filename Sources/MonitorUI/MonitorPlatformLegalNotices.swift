import Foundation
import MonitorPresentation

/// The platform's third-party notices every app ships: OpenCine's THIRD-PARTY-NOTICES.md followed
/// by the license texts of the fonts and icons MonitorUI bundles. The notices file is a generated
/// copy of the repository file (`scripts/stage-legal-resources.py --check` fails on drift); the
/// license texts are the resources the shared UI already carries.
public enum MonitorPlatformLegalNotices {
    /// Bundle paths in reading order.
    static let parts: [(name: String, ext: String, subdirectory: String?)] = [
        ("THIRD-PARTY-NOTICES", "md", "Legal"),
        ("OFL-Sora", "txt", nil),
        ("LICENSE", "txt", "Icons/lucide"),
        ("LICENSE-Tabler", "txt", "Icons/assist"),
    ]

    /// The joined notices, or unavailable when this build lacks any part.
    public static var document: MonitorLegalDocument {
        MonitorLegalDocuments.bundledText(parts.map {
            MonitorLegalDocuments.resource($0.name, extension: $0.ext, subdirectory: $0.subdirectory, in: .module)
        })
    }

    /// The joined text for a host's licenses page, or nil when this build lacks any part.
    public static var text: String? {
        if case .text(let text) = document { return text }
        return nil
    }
}
