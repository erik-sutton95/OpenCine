import Testing

@testable import OpenCineDesktopKit

/// The module window's keys and its toolbar's take readout (spec
/// 2026-11-25-desktop-camera-window-toolbar-design.md, Keyboard and Toolbar).
@Suite struct DesktopKeyCommandsTests {
    private func action(
        _ input: String, _ modifiers: DesktopModifiers = [], text: Bool = false, tabs: Int = 3
    ) -> DesktopShortcut? {
        DesktopKeyCommands.action(input: input, modifiers: modifiers, textHasFocus: text, tabCount: tabs)
    }

    @Test func shortcutTable() {
        #expect(action("r", .command) == .record)
        #expect(action(",", .command) == .settings)
        #expect(action("m", [.command, .shift]) == .media)
        #expect(action("M", [.command, .shift]) == .media)
        #expect(action("1", .command) == .tab(0))
        #expect(action("3", .command) == .tab(2))
        #expect(action("9", .command, tabs: 9) == .tab(8))
        #expect(action("\t", .control) == .nextTab)
        #expect(action("\t", [.control, .shift]) == .previousTab)
        #expect(action("d") == .overlays)
        // Other modifiers do not reach these actions.
        #expect(action("r") == nil)
        #expect(action("r", [.command, .shift]) == nil)
        #expect(action("m", .command) == nil)
        #expect(action("d", .shift) == nil)
        #expect(action("d", .command) == nil)
        #expect(action("x", .command) == nil)
        // Every key the table answers is registered with the window.
        for key in DesktopKeyCommands.registered {
            #expect(
                DesktopKeyCommands.action(
                    input: key.input, modifiers: key.modifiers, textHasFocus: false, tabCount: 9) != nil,
                "\(key.input) \(key.modifiers.rawValue)")
        }
        #expect(DesktopKeyCommands.registered.count == 3 + 9 + 2 + 1)
    }

    @Test func plainKeysAreIgnoredWhileTextHasFocus() {
        // Typing a network name or password types the letter.
        #expect(action("d", text: true) == nil)
        // Command shortcuts still work: they type nothing.
        #expect(action("r", .command, text: true) == .record)
        #expect(action(",", .command, text: true) == .settings)
        #expect(action("2", .command, text: true) == .tab(1))
    }

    @Test func tabShortcutBeyondTheTabsDoesNothing() {
        #expect(action("4", .command, tabs: 3) == nil)
        #expect(action("1", .command, tabs: 0) == nil)
        #expect(action("\t", .control, tabs: 1) == nil)
        #expect(action("\t", [.control, .shift], tabs: 0) == nil)
        // The tab to switch to, from the selected one, wrapping around.
        #expect(DesktopKeyCommands.tabIndex(for: .nextTab, selected: 2, tabCount: 3) == 0)
        #expect(DesktopKeyCommands.tabIndex(for: .previousTab, selected: 0, tabCount: 3) == 2)
        #expect(DesktopKeyCommands.tabIndex(for: .nextTab, selected: nil, tabCount: 3) == 0)
        #expect(DesktopKeyCommands.tabIndex(for: .tab(1), selected: 0, tabCount: 3) == 1)
        #expect(DesktopKeyCommands.tabIndex(for: .tab(3), selected: 0, tabCount: 3) == nil)
        #expect(DesktopKeyCommands.tabIndex(for: .record, selected: 0, tabCount: 3) == nil)
    }

    @Test func takeStateFollowsTheMonitor() {
        // Recording started on the camera body reaches the monitor, then the toolbar.
        #expect(
            DesktopTake.recording(timecode: "00:01:02:03").title
                == .init(state: "REC", timecode: "00:01:02:03", role: .recording))
        #expect(
            DesktopTake.standby(timecode: "00:00:00").title
                == .init(state: "STBY", timecode: "00:00:00", role: .muted))
        // A body without timecode shows the state alone, never a dash.
        #expect(DesktopTake.standby(timecode: nil).title == .init(state: "STBY", timecode: nil, role: .muted))
        #expect(DesktopTake.recording(timecode: " ").title.timecode == nil)
        #expect(DesktopTake.standby(timecode: "--:--:--").title.timecode == nil)
        #expect(DesktopTake.recording(timecode: nil).isRecording)
        #expect(!DesktopTake.standby(timecode: nil).isRecording)
        // A monitor that does not know whether the body records (no control link yet, a dropped
        // link) shows no state word rather than claiming standby.
        #expect(DesktopTake(recording: nil, timecode: "00:00:01").title == .init(state: nil, timecode: "00:00:01", role: .muted))
        #expect(DesktopTake(recording: true, timecode: nil) == .recording(timecode: nil))
        #expect(DesktopTake(recording: false, timecode: "1") == .standby(timecode: "1"))
    }

    @Test func aStaleMonitorCannotClearTheCurrentRegistration() {
        // A monitor leaving the screen after a new one registered leaves the new one's actions.
        var registry = DesktopRegistry<String>()
        let old = DesktopRegistry<String>.Owner(), new = DesktopRegistry<String>.Owner()
        registry.register("old", owner: old)
        registry.register("new", owner: new)
        registry.unregister(owner: old)
        #expect(registry.current == "new")
        registry.unregister(owner: new)
        #expect(registry.current == nil)
        // The same monitor coming back registers again.
        registry.register("new again", owner: new)
        #expect(registry.current == "new again")
    }
}
