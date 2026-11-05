import Foundation

public struct InstalledModule: Equatable, Sendable {
    public let manifest: ModuleManifest
    public let bundleURL: URL
    public let compatible: Bool
}

/// The modules installed in the dock's modules folder: `<directory>/<id>/module.json` plus the bundle.
public struct ModuleRegistry: Sendable {
    public let modulesDirectory: URL
    public let dockVersion: String

    public init(modulesDirectory: URL, dockVersion: String) {
        self.modulesDirectory = modulesDirectory
        self.dockVersion = dockVersion
    }

    /// Valid modules, sorted by ID. A broken folder is skipped, and never hides the others.
    public func installed() -> [InstalledModule] {
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: modulesDirectory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder -> InstalledModule? in
            guard
                let data = try? Data(contentsOf: folder.appendingPathComponent("module.json")),
                let manifest = try? JSONDecoder().decode(ModuleManifest.self, from: data)
            else { return nil }
            let bundle = folder.appendingPathComponent(manifest.bundleName)
            guard FileManager.default.fileExists(atPath: bundle.path) else { return nil }
            return InstalledModule(
                manifest: manifest, bundleURL: bundle,
                compatible: manifest.isCompatible(withDock: dockVersion))
        }.sorted { $0.manifest.id < $1.manifest.id }
    }
}
