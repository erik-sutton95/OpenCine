import OpenCineMedia
import Testing

/// ZAB-524: the header says why Share waits on the camera cache, then returns to the clip facts.
/// Same table as Kotlin `MonitorPlaybackNoticeTest`.
struct MonitorPlaybackNoticeTests {
    @Test func noticeReplacesTheFactsLineOnlyWhileItIsSet() {
        let facts = "3840x2160 · 25p · MOV"
        #expect(MonitorPlaybackSourceValues().headerSubtitle(facts: facts) == facts)
        #expect(MonitorPlaybackSourceValues(notice: " ").headerSubtitle(facts: facts) == facts)
        let caching = "Still caching from the camera. Share will finish the copy first."
        #expect(MonitorPlaybackSourceValues(notice: caching).headerSubtitle(facts: facts) == caching)
    }
}
