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
    @Test func passcodeRuleTakesAnyTextOfFourCharactersTrimmed() {
        #expect(MonitorWatcherPasscodeRule.minimumLength == 4)
        #expect(MonitorWatcherPasscodeRule.entry("") == .open)
        #expect(MonitorWatcherPasscodeRule.entry(" \t\n\u{00A0}") == .open)
        #expect(MonitorWatcherPasscodeRule.entry("abc") == .tooShort)
        #expect(MonitorWatcherPasscodeRule.entry("  abc  ") == .tooShort)
        #expect(MonitorWatcherPasscodeRule.entry("abcd") == .code("abcd"))
        #expect(MonitorWatcherPasscodeRule.entry(" set pass\n") == .code("set pass"))
        #expect(MonitorWatcherPasscodeRule.entry("a1 b2 c3") == .code("a1 b2 c3"))
        #expect(MonitorWatcherPasscodeRule.entry("\u{2003}pässwörd\u{0085}") == .code("pässwörd"))
        // Unicode scalars, so Android's code-point count agrees.
        #expect(MonitorWatcherPasscodeRule.entry("🎬🎬") == .tooShort)
        #expect(MonitorWatcherPasscodeRule.entry("🎬🎬🎬🎬") == .code("🎬🎬🎬🎬"))
        #expect(MonitorWatcherPasscodeRule.Entry.open.passcode == "")
        #expect(MonitorWatcherPasscodeRule.Entry.code("abcd").passcode == "abcd")
        #expect(MonitorWatcherPasscodeRule.Entry.tooShort.passcode == nil)
    }
    @Test func everySavedPasscodeFormStaysUsable() {
        // OpenZCine saved four decimal digits; OpenPocketCine and OpenInstaCine saved free text of
        // any length, untrimmed. Each still takes effect when chosen again (four or more) and is
        // always a valid watcher answer, so a host keeping it stays joinable.
        for saved in ["0000", "4821", "١٢٣٤", "set pass", "pässwörd", "abcdefghijklmnopqrstuvwxyz0123456789"] {
            #expect(MonitorWatcherPasscodeRule.entry(saved) == .code(saved), "\(saved)")
            #expect(MonitorWatcherPasscodeRule.answer(saved) == saved, "\(saved)")
        }
        for saved in ["a", "ab1", " abc "] {
            #expect(MonitorWatcherPasscodeRule.answer(saved) == MonitorWatcherPasscodeRule.normalized(saved))
        }
        #expect(MonitorWatcherPasscodeRule.answer(" 1234 ") == "1234")
        #expect(MonitorWatcherPasscodeRule.answer("  ") == nil)
    }
}
