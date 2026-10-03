import Foundation
import OpenCineCore

/// A catalog value uses only content-qualified source identities. Locations and filenames
/// never merge assets; a removal for an old identity cannot erase its successor.
public struct MediaCatalog: Equatable, Sendable {
    public let assets: [MediaAsset]
    public let volumes: [StorageVolume]?
    public let complete: Bool
    public init(assets: [MediaAsset] = [], volumes: [StorageVolume]? = nil, complete: Bool = false) {
        self.assets = assets; self.volumes = volumes; self.complete = complete
    }
    public func applying(_ delta: MediaCatalogDelta) -> Self {
        let removed = Set(delta.removed)
        var order = delta.reset ? [] : assets.map(\.id).filter { !removed.contains($0) }
        var values = Dictionary((delta.reset ? [] : assets).filter { !removed.contains($0.id) }
            .map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        for asset in delta.upserts {
            if values[asset.id] == nil { order.append(asset.id) }
            values[asset.id] = asset
        }
        return Self(assets: order.compactMap { values[$0] }, volumes: delta.volumes ?? volumes,
            complete: delta.complete)
    }
}
