import Foundation

/// What a camera module says about itself, in the `module.json` beside its app bundle.
public struct ModuleManifest: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    /// The name receiving apps show for this module's input.
    public let inputName: String
    public let version: String
    public let minimumDockVersion: String
    public let bundleName: String

    public init(
        id: String, displayName: String, inputName: String, version: String,
        minimumDockVersion: String, bundleName: String
    ) {
        self.id = id
        self.displayName = displayName
        self.inputName = inputName
        self.version = version
        self.minimumDockVersion = minimumDockVersion
        self.bundleName = bundleName
    }

    public func isCompatible(withDock dockVersion: String) -> Bool {
        dockVersion.compare(minimumDockVersion, options: .numeric) != .orderedAscending
    }
}
