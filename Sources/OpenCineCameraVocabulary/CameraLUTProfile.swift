import Foundation

/// Integration-declared camera looks. Shared resolution does not inspect camera identity.
public struct CameraLUTProfile: Equatable, Sendable {
    public var automatic: [ColorMode: LUTSource]
    public var selections: [LUTSelection: LUTSource]

    public init(automatic: [ColorMode: LUTSource] = [:],
        selections: [LUTSelection: LUTSource] = [:]) {
        self.automatic = automatic
        self.selections = selections
    }
}
