import Foundation

/// What a Multiview stage may do with one integration's cameras: whether a camera may join a
/// stage, whether the stage shows its picture, and whether the coordinator may find a member by
/// probing hosts. Every integration supplies one, with or without a `StationCommissioner`, so an
/// integration whose cameras join a network only from their own menus still answers. Kotlin twin:
/// `MultiviewCameraPolicy`.
public struct MultiviewCameraPolicy<Camera>: Sendable {
    private let qualify: @Sendable (Camera, Bool) -> MulticamQualification
    private let preview: @Sendable (Camera) -> Bool
    /// Whether the coordinator may find a member's address by probing hosts on the shared network
    /// (`MultiviewMemberLink.probe`). False for cameras that must never be dialled unasked: the
    /// integration then finds members from its own sightings.
    public let discoversByProbe: Bool
    private let key: (@Sendable (String) -> String)?

    public init(
        discoversByProbe: Bool = true,
        hostKey: (@Sendable (_ address: String) -> String)? = nil,
        qualification: @escaping @Sendable (_ camera: Camera, _ experimental: Bool) ->
            MulticamQualification,
        hasPreview: @escaping @Sendable (_ camera: Camera) -> Bool
    ) {
        self.discoversByProbe = discoversByProbe
        key = hostKey
        qualify = qualification
        preview = hasPreview
    }

    /// Whether this camera, in this configuration, may join a stage.
    public func qualification(_ camera: Camera, experimental: Bool) -> MulticamQualification {
        qualify(camera, experimental)
    }

    /// Whether a stage shows this camera's picture; without it only the network join is checked.
    public func hasPreview(_ camera: Camera) -> Bool { preview(camera) }

    /// The form two addresses of this integration's cameras compare in (an integration that
    /// normalizes hosts supplies its rule); the address itself by default. The coordinator compares
    /// reserved, excluded and controlled hosts by this key.
    public func hostKey(_ address: String) -> String { key?(address) ?? address }
}
