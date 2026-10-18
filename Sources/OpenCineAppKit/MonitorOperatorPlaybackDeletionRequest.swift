import Foundation
import OpenCineMedia

/// An app captures related targets and native cleanup in the performer. The existing library
/// authority admits source IO and its completion grants only the planned presentation return.
@MainActor public struct MonitorOperatorPlaybackDeletionRequest {
    public let confirmation: MonitorPlaybackDeletionConfirmation
    public let authority: MonitorMediaLibraryDeletionAuthority
    public let perform: @MainActor () async -> Void
    public init(confirmation: MonitorPlaybackDeletionConfirmation,
        authority: MonitorMediaLibraryDeletionAuthority,
        perform: @escaping @MainActor () async -> Void) {
        self.confirmation = confirmation; self.authority = authority; self.perform = perform
    }
}
