import OpenCineMedia
import Testing

/// ZAB-524: the header says why Share waits on the camera cache, then returns to the clip facts.
/// Same tables as Kotlin `MonitorPlaybackNoticeTest`.
struct MonitorPlaybackNoticeTests {
    @Test func noticeReplacesTheFactsLineOnlyWhileItIsSet() {
        let facts = "3840x2160 · 25p · MOV"
        #expect(MonitorPlaybackSourceValues().headerSubtitle(facts: facts) == facts)
        #expect(MonitorPlaybackSourceValues(notice: " ").headerSubtitle(facts: facts) == facts)
        let caching = "Still caching from the camera. Share will finish the copy first."
        #expect(MonitorPlaybackSourceValues(notice: caching).headerSubtitle(facts: facts) == caching)
    }

    /// A camera that does not share its files over this connection: the player's failure reads the
    /// source's reason, and the reason never shows while the clip has not failed.
    @Test func unavailableReasonReplacesOnlyAPlayerFailure() {
        let generic = "Could not open that clip."
        let reason = "The camera is not sharing its files right now."
        #expect(MonitorPlaybackSourceValues().loadError(player: generic) == generic)
        #expect(MonitorPlaybackSourceValues(unavailableReason: " ").loadError(player: generic) == generic)
        #expect(MonitorPlaybackSourceValues(unavailableReason: reason).loadError(player: generic) == reason)
        #expect(MonitorPlaybackSourceValues(unavailableReason: reason).loadError(player: nil) == nil)
    }
}
