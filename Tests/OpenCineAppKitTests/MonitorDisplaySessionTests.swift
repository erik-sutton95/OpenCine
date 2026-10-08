import Testing
@testable import OpenCineAppKit

@Suite("Operator display intent and editor return")
@MainActor struct MonitorDisplaySessionTests {
    @Test func sourceOrderCyclesAndWraps() {
        guard #available(macOS 14, *) else { return }
        let model = MonitorDisplaySession(mode: "live")
        #expect(model.cycle(order: ["live", "clean", "controls"]))
        #expect(model.mode == "clean")
        #expect(model.cycle(order: ["live", "clean", "controls"]))
        #expect(model.mode == "controls")
        #expect(model.cycle(order: ["live", "clean", "controls"]))
        #expect(model.mode == "live")
    }

    @Test func lockRefusesCycleAndSelection() {
        guard #available(macOS 14, *) else { return }
        let model = MonitorDisplaySession(mode: "live")
        model.locked = true
        #expect(!model.cycle(order: ["live", "clean"]))
        #expect(!model.select("clean", order: ["live", "clean"]))
        #expect(model.mode == "live")
        model.locked = false
        #expect(model.select("clean", order: ["live", "clean"]))
    }

    @Test func removedSourceModeIsNeverSelected() {
        guard #available(macOS 14, *) else { return }
        let model = MonitorDisplaySession(mode: "controls")
        #expect(!model.select("controls", order: ["clean", "live"]))
        #expect(model.reconcile(order: ["clean", "live"]))
        #expect(model.mode == "clean")
        #expect(model.cycle(order: ["clean", "live"]))
        #expect(model.mode == "live")
    }

    @Test func disabledModeCanBeEditedAndDoneReturnsToItOnce() {
        guard #available(macOS 14, *) else { return }
        let model = MonitorDisplaySession(mode: "live")
        model.beginEditing("clean")
        #expect(model.mode == "clean")
        #expect(model.isEditing)
        #expect(model.finishEditing(order: ["live"]) == "clean")
        #expect(model.returnedMode == "clean")
        #expect(model.mode == "live")
        #expect(!model.isEditing)
        #expect(model.finishEditing(order: ["live"]) == nil)
    }

    @Test func retirementClearsEditorWithoutChangingIntent() {
        guard #available(macOS 14, *) else { return }
        let model = MonitorDisplaySession(mode: "live")
        model.beginEditing("clean")
        model.locked = true
        model.returnedMode = "controls"
        model.retireEditor()
        #expect(model.editingMode == nil)
        #expect(model.returnedMode == nil)
        #expect(model.mode == "clean")
        #expect(model.locked)
    }

    @Test func emptyAndUnknownOrdersDoNotInventMode() {
        guard #available(macOS 14, *) else { return }
        let model = MonitorDisplaySession(mode: "picture")
        #expect(!model.cycle(order: []))
        #expect(!model.reconcile(order: []))
        #expect(model.mode == "picture")
        #expect(MonitorDisplaySession.next(in: [], after: "picture") == nil)
        #expect(MonitorDisplaySession.next(in: ["clean", "live"], after: "picture") == "clean")
    }
}
