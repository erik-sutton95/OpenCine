import MonitorPresentation
import Testing

struct MonitorWatcherLayoutTests {
    @Test func readOnlySourceStillOwnsItsMeasuredPicture() {
        let source = MonitorWatcherTapSource(source: "source", revision: 1, canControl: false)
        let geometry = MonitorWatcherPictureGeometry(source: source,
            viewport: .init(width: 844, height: 390), feed: .init(x: 100, width: 640, height: 360),
            bottomClearance: 10, mirrored: true)
        #expect(geometry.belongs(to: source))
        #expect(geometry.feed.width == 640)
        #expect(geometry.mirrored)
    }
    @Test func measuredPictureCannotCrossSourceOrSameNameRevisionReplacement() {
        let source = MonitorWatcherTapSource(source: "same-name", revision: 1, canControl: true)
        let geometry = MonitorWatcherPictureGeometry(source: source, viewport: .init(), feed: .init(),
            bottomClearance: 10, mirrored: false)
        #expect(!geometry.belongs(to: .init(source: "same-name", revision: 3, canControl: true)))
        #expect(!geometry.belongs(to: .init(source: "replacement", revision: 1, canControl: true)))
    }
    @Test func connectionKeyLaneKeepsBothOriginalClearances() {
        #expect(MonitorWatcherControlPlacement.bottomInset(portrait: true) == 192)
        #expect(MonitorWatcherControlPlacement.bottomInset(portrait: false) == 84)
    }
    @Test func passcodeEntryRetainsFourDecimalDigitsAndRequiresACompleteDraft() {
        var draft = MonitorWatcherPasscodeDraft()
        draft.update("a1 b2 c3")
        #expect(draft.digits == "123")
        #expect(draft.complete == nil)
        draft.update("a1 b2 c3 d4 e5")
        #expect(draft.digits == "1234")
        #expect(draft.complete == "1234")
        draft.update("١٢٣٤")
        #expect(draft.complete == "١٢٣٤")
        draft.update("")
        #expect(draft.complete == nil)
    }
}
