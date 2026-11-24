import Testing

@testable import OpenCineDesktopKit

/// Which module window is on screen, where, and when the others go.
@Suite struct DockWindowCoordinatorTests {
    let f1 = WindowFrame(x: 0, y: 0, width: 1280, height: 800)
    let f2 = WindowFrame(x: 200, y: 100, width: 1280, height: 800)

    private typealias Command = DockWindowCoordinator.Command

    private func running(_ ids: [String], selected: String) -> DockWindowCoordinator {
        var c = DockWindowCoordinator(selectedID: selected, frame: f1)
        for id in ids { _ = c.moduleReady(id) }
        return c
    }

    @Test func selectingShowsNewBeforeHidingOld() {
        var c = running(["a", "b"], selected: "a")
        #expect(c.select("b") == [Command(moduleID: "b", message: .show(frame: f1))])
        #expect(c.moduleShown("b") == [Command(moduleID: "a", message: .hide)])
    }

    @Test func selectingTheSelectedTabDoesNothing() {
        var c = running(["a", "b"], selected: "a")
        #expect(c.select("a").isEmpty)
    }

    @Test func switchTimeoutHidesOldWindow() {
        var c = running(["a", "b"], selected: "a")
        _ = c.select("b")
        #expect(c.switchTimedOut("b") == [Command(moduleID: "a", message: .hide)])
        #expect(c.moduleShown("b").isEmpty)
    }

    @Test func rapidSwitchHidesEveryEarlierWindow() {
        var c = running(["a", "b", "c"], selected: "a")
        _ = c.select("b")
        _ = c.select("c")
        #expect(c.moduleShown("b").isEmpty)
        #expect(
            Set(c.moduleShown("c")) == [
                Command(moduleID: "a", message: .hide), Command(moduleID: "b", message: .hide),
            ])
    }

    @Test func movesFromTheVisibleModuleReachHiddenOnes() {
        var c = running(["a", "b", "c"], selected: "a")
        #expect(
            Set(c.windowMoved(by: "a", to: f2)) == [
                Command(moduleID: "b", message: .place(frame: f2)),
                Command(moduleID: "c", message: .place(frame: f2)),
            ])
        #expect(c.frame == f2)
    }

    @Test func movesFromAHiddenModuleAreIgnored() {
        var c = running(["a", "b"], selected: "a")
        #expect(c.windowMoved(by: "b", to: f2).isEmpty)
        #expect(c.frame == f1)
    }

    @Test func lateReadyModuleUsesCurrentFrame() {
        var c = running(["a"], selected: "a")
        _ = c.windowMoved(by: "a", to: f2)
        #expect(
            c.moduleReady("b") == [
                Command(moduleID: "b", message: .place(frame: f2)), Command(moduleID: "b", message: .hide),
            ])
    }

    @Test func selectedModuleStoppingShowsNextRunning() {
        var c = running(["a", "b"], selected: "a")
        #expect(c.moduleStopped("a") == [Command(moduleID: "b", message: .show(frame: f1))])
        #expect(c.selectedID == "b")
        #expect(!c.needsFallbackWindow)
    }

    @Test func lastModuleStoppingNeedsFallback() {
        var c = running(["a"], selected: "a")
        #expect(c.moduleStopped("a").isEmpty)
        #expect(c.needsFallbackWindow)
        #expect(c.moduleReady("a") == [Command(moduleID: "a", message: .show(frame: f1))])
        #expect(!c.needsFallbackWindow)
    }

    @Test func bringForwardShowsTheSelectedModule() {
        var c = running(["a", "b"], selected: "b")
        #expect(c.bringForward() == [Command(moduleID: "b", message: .show(frame: f1))])
    }

    /// The remembered tab keeps its place at launch even when another module is ready first.
    @Test func moduleReadyBeforeTheSelectedOneStandsInUntilItIsReady() {
        var c = DockWindowCoordinator(selectedID: "a", frame: f1)
        #expect(c.moduleReady("b") == [Command(moduleID: "b", message: .show(frame: f1))])
        #expect(c.selectedID == "a")
        #expect(c.moduleReady("a") == [Command(moduleID: "a", message: .show(frame: f1))])
        #expect(c.moduleShown("a") == [Command(moduleID: "b", message: .hide)])
    }

    /// A restarted tab is selected before it runs; the window on screen stays until it is ready.
    @Test func selectingAStoppedModuleKeepsTheCurrentWindowUntilItIsReady() {
        var c = running(["a", "b"], selected: "a")
        _ = c.moduleStopped("b")
        #expect(c.select("b").isEmpty)
        #expect(c.selectedID == "b")
        #expect(c.moduleReady("b") == [Command(moduleID: "b", message: .show(frame: f1))])
        #expect(c.switchTimedOut("b") == [Command(moduleID: "a", message: .hide)])
    }

    @Test func stoppedHiddenModuleGetsNoMoreCommands() {
        var c = running(["a", "b"], selected: "a")
        #expect(c.moduleStopped("b").isEmpty)
        #expect(c.windowMoved(by: "a", to: f2).isEmpty)
    }

    @Test func nothingRunningAtLaunchNeedsFallback() {
        let c = DockWindowCoordinator(selectedID: "a", frame: f1)
        #expect(c.needsFallbackWindow)
    }
}
