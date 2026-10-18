import MonitorPresentation
import Testing

struct MonitorMediaDragSelectionTests {
    private let ids = (0..<12).map(String.init)

    @Test func selectionSweepsInBothDirectionsAndRestoresOriginalStateOnReversal() throws {
        var sweep = try #require(
            MonitorMediaDragSelection(
                orderedIDs: ids, originID: "4", selectedIDs: ["1", "6", "hidden"]))
        #expect(sweep.selectedIDs == ["1", "4", "6", "hidden"])
        let extended = sweep.move(to: 8)
        #expect(extended)
        #expect(sweep.selectedIDs == ["1", "4", "5", "6", "7", "8", "hidden"])
        let reversed = sweep.move(to: 2)
        #expect(reversed)
        #expect(sweep.selectedIDs == ["1", "2", "3", "4", "6", "hidden"])
        let restored = sweep.move(to: 4)
        #expect(restored)
        #expect(sweep.selectedIDs == ["1", "4", "6", "hidden"])
        let unchanged = sweep.move(to: 4)
        #expect(!unchanged)
    }

    @Test func selectedOriginDeselectsAndRestoresMixedPriorSelection() throws {
        var sweep = try #require(
            MonitorMediaDragSelection(
                orderedIDs: ids, originID: "4", selectedIDs: ["1", "4", "6", "9"]))
        #expect(sweep.selectedIDs == ["1", "6", "9"])
        sweep.move(to: 9)
        #expect(sweep.selectedIDs == ["1"])
        sweep.move(to: 2)
        #expect(sweep.selectedIDs == ["1", "6", "9"])
        sweep.move(to: 0)
        #expect(sweep.selectedIDs == ["6", "9"])
        sweep.move(to: 4)
        #expect(sweep.selectedIDs == ["1", "6", "9"])
    }

    @Test func missingOriginIsRejectedAndIndexJumpsAreBounded() throws {
        #expect(MonitorMediaDragSelection(orderedIDs: [], originID: "0", selectedIDs: []) == nil)
        var sweep = try #require(
            MonitorMediaDragSelection(orderedIDs: ids, originID: "0", selectedIDs: []))
        sweep.move(to: Int.max)
        #expect(sweep.selectedIDs == Set(ids))
        sweep.move(to: Int.min)
        #expect(sweep.selectedIDs == ["0"])
    }

    @Test func autoScrollHasQuietCenterEasedEdgesAndFiniteSpeed() {
        #expect(MonitorMediaSelectionScroll.velocity(pointerY: 200, viewportHeight: 400) == 0)
        #expect(MonitorMediaSelectionScroll.velocity(pointerY: 28, viewportHeight: 400) == -180)
        #expect(MonitorMediaSelectionScroll.velocity(pointerY: 372, viewportHeight: 400) == 180)
        #expect(MonitorMediaSelectionScroll.velocity(pointerY: -100, viewportHeight: 400) == -720)
        #expect(MonitorMediaSelectionScroll.velocity(pointerY: 500, viewportHeight: 400) == 720)
        #expect(MonitorMediaSelectionScroll.velocity(pointerY: .nan, viewportHeight: 400) == 0)
        #expect(MonitorMediaSelectionScroll.velocity(pointerY: 0, viewportHeight: 0) == 0)
        #expect(MonitorMediaSelectionScroll.velocity(pointerY: 15, viewportHeight: 30) == 0)
    }

    @Test func fixedLinearEdgePolicyRetainsNativeBandAndBoundedSpeed() {
        let policy = MonitorMediaSelectionConfiguration(
            holdMilliseconds: 180, movementTolerance: 40, allowsSelectionEntry: false,
            sweepsSideways: false, edgeBand: 90, maximumEdgeSpeed: 620,
            edgeCurve: .linear, viewportEdgeLimitRatio: nil)
        #expect(policy.holdMilliseconds == 180)
        #expect(!policy.allowsSelectionEntry && !policy.sweepsSideways)
        #expect(
            MonitorMediaSelectionScroll.velocity(
                pointerY: 45, viewportHeight: 400, configuration: policy) == -310)
        #expect(
            MonitorMediaSelectionScroll.velocity(
                pointerY: 355, viewportHeight: 400, configuration: policy) == 310)
        #expect(
            MonitorMediaSelectionScroll.velocity(
                pointerY: -1, viewportHeight: 400, configuration: policy) == -620)
        #expect(
            MonitorMediaSelectionScroll.velocity(
                pointerY: 401, viewportHeight: 400, configuration: policy) == 620)
        // A fixed band remains 90pt on a compact 200pt viewport.
        #expect(
            MonitorMediaSelectionScroll.velocity(
                pointerY: 45, viewportHeight: 200, configuration: policy) == -310)
        #expect(
            MonitorMediaSelectionScroll.velocity(
                pointerY: 100, viewportHeight: 200, configuration: policy) == 0)
    }

    @Test func configuredVelocityKeepsUnknownGeometryQuietAndStandardDefaultsExact() {
        let standard = MonitorMediaSelectionConfiguration.standard
        #expect(standard.holdMilliseconds == 280 && standard.movementTolerance == 8)
        #expect(standard.allowsSelectionEntry && standard.sweepsSideways)
        for y in [-100.0, 0, 28, 200, 372, 500] {
            #expect(
                MonitorMediaSelectionScroll.velocity(pointerY: y, viewportHeight: 400)
                    == MonitorMediaSelectionScroll.velocity(
                        pointerY: y, viewportHeight: 400, configuration: standard))
        }
        #expect(
            MonitorMediaSelectionScroll.velocity(
                pointerY: .infinity, viewportHeight: 400, configuration: standard) == 0)
        #expect(
            MonitorMediaSelectionScroll.velocity(
                pointerY: 0, viewportHeight: .nan, configuration: standard) == 0)
    }

    @Test func nativeRoundedClockStepsKeepRateIndependentBoundAndIgnoreInvalidTime() {
        let policy = MonitorMediaSelectionConfiguration(
            edgeBand: 90, maximumEdgeSpeed: 620, edgeCurve: .linear,
            viewportEdgeLimitRatio: nil, roundsScrollSteps: true)
        #expect(
            MonitorMediaSelectionScroll.step(
                pointerY: 400, viewportHeight: 400, elapsed: 1 / 120, configuration: policy) == 5)
        #expect(
            MonitorMediaSelectionScroll.step(
                pointerY: -1, viewportHeight: 400, elapsed: 0.5 / 620, configuration: policy) == -1)
        #expect(
            MonitorMediaSelectionScroll.step(
                pointerY: 400, viewportHeight: 400, elapsed: 0.2, configuration: policy) == 31)
        #expect(
            MonitorMediaSelectionScroll.step(
                pointerY: 400, viewportHeight: 400, elapsed: .nan, configuration: policy) == 0)
    }

    @Test func controllerHoldThenSweepPublishesOncePerEndpoint() throws {
        var controller = MonitorMediaSelectionController()
        controller.bind(ids: ids, selecting: false, selected: [])
        controller.down(id: "1", x: 10, y: 10, timeMilliseconds: 1_000)
        #expect(controller.holdDue(timeMilliseconds: 1_279) == nil)
        #expect(
            controller.holdDue(timeMilliseconds: 1_280)
                == .selection(selecting: true, selected: ["1"], feedback: .began))
        #expect(controller.move(id: "1", x: 10, y: 12) == nil)
        #expect(
            controller.move(id: "4", x: 10, y: 80)
                == .selection(selecting: true, selected: ["1", "2", "3", "4"], feedback: .changed))
        #expect(controller.move(id: "4", x: 12, y: 82) == nil)
        #expect(controller.up(childConsumed: false) == nil)
        #expect(!controller.consuming)
    }

    @Test func childOwnedBrowseHoldNeverClaimsTheSameTouchAfterSelectionEntry() {
        var controller = MonitorMediaSelectionController(
            configuration: .init(allowsSelectionEntry: false))
        controller.bind(ids: ids, selecting: false, selected: [])
        controller.down(id: "0", x: 0, y: 0, timeMilliseconds: 0)
        controller.bind(ids: ids, selecting: true, selected: ["0"])
        #expect(controller.holdDue(timeMilliseconds: 280) == nil)
        #expect(controller.move(id: "3", x: 40, y: 0) == nil)
        #expect(controller.up(childConsumed: false) == nil)
        #expect(controller.selected == ["0"] && !controller.consuming)
        controller.down(id: "1", x: 0, y: 0, timeMilliseconds: 300)
        #expect(
            controller.holdDue(timeMilliseconds: 580)
                == .selection(selecting: true, selected: ["0", "1"], feedback: .began))
    }

    @Test func deliberateHoldPolicyYieldsEveryPreHoldDragAndFramesStationaryEdges() {
        var controller = MonitorMediaSelectionController(
            configuration: .init(
                allowsSelectionEntry: false, sweepsSideways: false, edgeBand: 72,
                maximumEdgeSpeed: 620, edgeCurve: .linear, viewportEdgeLimitRatio: nil))
        controller.bind(ids: ids, selecting: true, selected: ["0"])
        controller.down(id: "1", x: 0, y: 0, timeMilliseconds: 0)
        #expect(controller.move(id: "3", x: 40, y: 0) == nil)
        #expect(controller.shouldYieldToScroll())
        #expect(controller.holdDue(timeMilliseconds: 280) == nil)
        #expect(controller.up(childConsumed: false) == nil)
        #expect(controller.selected == ["0"])
        controller.down(id: "1", x: 10, y: 800, timeMilliseconds: 1_000)
        _ = controller.holdDue(timeMilliseconds: 1_280)
        #expect(controller.edgeScroll(elapsed: 0.2, viewportHeight: 800) == 31)
        #expect(controller.edgeScroll(elapsed: 0.2, viewportHeight: 800) == 31)
        #expect(
            controller.afterScroll(hitID: "4")
                == .selection(
                    selecting: true, selected: ["0", "1", "2", "3", "4"], feedback: .changed))
        #expect(controller.afterScroll(hitID: "4") == nil)
        controller.cancel()
        #expect(controller.edgeScroll(elapsed: 0.2, viewportHeight: 800) == 0)
        #expect(controller.up(childConsumed: false) == nil)
    }

    @Test func aViewportResizeUnderAStillSweepScrollsOnlyOnceThePointerMoves() {
        // Kotlin twin: MonitorMediaSelectionTest.aViewportResizeUnderAStillSweepScrollsOnlyOnceTheFingerMoves.
        var controller = MonitorMediaSelectionController()
        controller.bind(ids: ids, selecting: false, selected: [])
        controller.down(id: "0", x: 10, y: 700, timeMilliseconds: 0)
        _ = controller.holdDue(timeMilliseconds: 280)
        #expect(controller.edgeVelocity(pointerY: 700, viewportHeight: 800) == 0)
        // The selection tray shrinks the viewport to 720: the same still pointer now lies in its bottom band.
        controller.viewportResized(pointerY: 700)
        #expect(controller.edgeVelocity(pointerY: 700, viewportHeight: 720) == 0)
        #expect(controller.edgeScroll(elapsed: 0.1, viewportHeight: 720) == 0)
        // A sideways sweep along the row keeps the edge held.
        _ = controller.move(id: "1", x: 200, y: 702)
        #expect(controller.edgeVelocity(pointerY: 702, viewportHeight: 720) == 0)
        #expect(controller.edgeScroll(elapsed: 0.1, viewportHeight: 720) == 0)
        // The pointer itself moving towards the edge arms it again.
        _ = controller.move(id: "1", x: 200, y: 712)
        #expect(controller.edgeVelocity(pointerY: 712, viewportHeight: 720) > 0)
        #expect(controller.edgeScroll(elapsed: 0.1, viewportHeight: 720) > 0)
        // A new sweep starts armed: a still hold at the edge of an unchanged viewport scrolls.
        _ = controller.up(childConsumed: false)
        controller.down(id: "2", x: 10, y: 712, timeMilliseconds: 1_000)
        _ = controller.holdDue(timeMilliseconds: 1_280)
        #expect(controller.edgeVelocity(pointerY: 712, viewportHeight: 720) > 0)
    }

    @Test func changedPolicyOrExternalSelectionExitRetiresAnActiveClock() {
        var controller = MonitorMediaSelectionController()
        controller.bind(ids: ids, selecting: true, selected: [])
        controller.down(id: "0", x: 10, y: 800, timeMilliseconds: 0)
        _ = controller.holdDue(timeMilliseconds: 280)
        #expect(controller.consuming)
        controller.configuration = .init(sweepsSideways: false)
        #expect(!controller.consuming)
        #expect(controller.edgeScroll(elapsed: 0.2, viewportHeight: 800) == 0)
        #expect(controller.up(childConsumed: false) == nil)
        controller.down(id: "1", x: 10, y: 800, timeMilliseconds: 1_000)
        _ = controller.holdDue(timeMilliseconds: 1_280)
        #expect(controller.consuming)
        controller.bind(ids: ids, selecting: false, selected: controller.selected)
        #expect(!controller.consuming && !controller.selecting)
        #expect(controller.edgeScroll(elapsed: 0.2, viewportHeight: 800) == 0)
    }

    @Test func replacedContextAndReorderedCatalogRejectLateHitsAndTerminalUpdates() {
        var controller = MonitorMediaSelectionController()
        controller.bind(ids: ids, selecting: true, selected: ["hidden"], context: "owner-a")
        controller.down(id: "0", x: 10, y: 800, timeMilliseconds: 0)
        _ = controller.holdDue(timeMilliseconds: 280)
        controller.bind(
            ids: ids, selecting: true, selected: controller.selected, context: "owner-b")
        #expect(!controller.consuming)
        #expect(controller.afterScroll(hitID: "4") == nil)
        #expect(controller.holdDue(timeMilliseconds: 5_000) == nil)
        #expect(controller.up(childConsumed: false) == nil)
        #expect(controller.selected == ["0", "hidden"])
        controller.down(id: "1", x: 10, y: 800, timeMilliseconds: 6_000)
        _ = controller.holdDue(timeMilliseconds: 6_280)
        controller.bind(
            ids: ids.reversed(), selecting: true, selected: controller.selected, context: "owner-b")
        #expect(!controller.consuming)
        #expect(controller.move(id: "5", x: 40, y: 810) == nil)
        #expect(controller.afterScroll(hitID: "5") == nil)
    }

    @Test func childConsumedTapAndMissingHitCannotOpenOrChangeAnotherSourceIdentity() {
        let distinct = ["volume-a/same.MOV", "volume-b/same.MOV"]
        var controller = MonitorMediaSelectionController()
        controller.bind(ids: distinct, selecting: false, selected: [])
        controller.down(id: distinct[0], x: 0, y: 0, timeMilliseconds: 0)
        #expect(controller.up(childConsumed: true) == nil)
        controller.down(id: "retired/same.MOV", x: 0, y: 0, timeMilliseconds: 1_000)
        #expect(controller.holdDue(timeMilliseconds: 1_280) == nil)
        #expect(controller.up(childConsumed: false) == nil)
        controller.cancel()
        controller.down(id: distinct[1], x: 0, y: 0, timeMilliseconds: 2_000)
        #expect(
            controller.holdDue(timeMilliseconds: 2_280)
                == .selection(selecting: true, selected: [distinct[1]], feedback: .began))
    }

}
