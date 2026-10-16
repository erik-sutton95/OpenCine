package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MonitorMediaSelectionTest {
    private val ids = (0 until 12).map { it.toString() }
    private val letters = listOf("a", "b", "c", "d", "e", "f", "g", "h", "i", "j")

    @Test fun selectionSweepsInBothDirectionsAndRestoresOriginalStateOnReversal() {
        val sweep = MonitorMediaDragSelection.start(ids, "4", setOf("1", "6", "hidden"))
        assertNotNull(sweep)
        assertEquals(setOf("1", "4", "6", "hidden"), sweep.selectedIds)
        assertTrue(sweep.move(8))
        assertEquals(setOf("1", "4", "5", "6", "7", "8", "hidden"), sweep.selectedIds)
        assertTrue(sweep.move(2))
        assertEquals(setOf("1", "2", "3", "4", "6", "hidden"), sweep.selectedIds)
        assertTrue(sweep.move(4))
        assertEquals(setOf("1", "4", "6", "hidden"), sweep.selectedIds)
        assertFalse(sweep.move(4))
    }

    @Test fun selectedOriginDeselectsAndRestoresMixedPriorSelection() {
        val sweep = MonitorMediaDragSelection.start(ids, "4", setOf("1", "4", "6", "9"))
        assertNotNull(sweep)
        assertEquals(setOf("1", "6", "9"), sweep.selectedIds)
        sweep.move(9)
        assertEquals(setOf("1"), sweep.selectedIds)
        sweep.move(2)
        assertEquals(setOf("1", "6", "9"), sweep.selectedIds)
        sweep.move(0)
        assertEquals(setOf("6", "9"), sweep.selectedIds)
        sweep.move(4)
        assertEquals(setOf("1", "6", "9"), sweep.selectedIds)
    }

    @Test fun missingOriginIsRejectedAndIndexJumpsAreBounded() {
        assertNull(MonitorMediaDragSelection.start(emptyList(), "0", emptySet()))
        val sweep = MonitorMediaDragSelection.start(ids, "0", emptySet())
        assertNotNull(sweep)
        sweep.move(Int.MAX_VALUE)
        assertEquals(ids.toSet(), sweep.selectedIds)
        sweep.move(Int.MIN_VALUE)
        assertEquals(setOf("0"), sweep.selectedIds)
    }

    @Test fun autoScrollHasQuietCenterEasedEdgesAndFiniteSpeed() {
        assertEquals(0f, MonitorMediaSelectionPolicy.edgeVelocity(200f, 400f))
        assertEquals(-180f, MonitorMediaSelectionPolicy.edgeVelocity(28f, 400f))
        assertEquals(180f, MonitorMediaSelectionPolicy.edgeVelocity(372f, 400f))
        assertEquals(-720f, MonitorMediaSelectionPolicy.edgeVelocity(-100f, 400f))
        assertEquals(720f, MonitorMediaSelectionPolicy.edgeVelocity(500f, 400f))
        assertEquals(0f, MonitorMediaSelectionPolicy.edgeVelocity(Float.NaN, 400f))
        assertEquals(0f, MonitorMediaSelectionPolicy.edgeVelocity(0f, 0f))
        assertEquals(0f, MonitorMediaSelectionPolicy.edgeVelocity(15f, 30f))
        assertEquals(minOf(56f, 400f / 3f), MonitorMediaSelectionPolicy.edgeBand(400f))
        assertEquals(10f, MonitorMediaSelectionPolicy.edgeBand(30f))
    }

    @Test fun controllerHoldThenSweepPublishesOncePerEndpoint() {
        val controller = MonitorMediaSelectionController()
        controller.bind(letters, false, emptySet())
        controller.down("b", 10f, 10f, 1_000L)
        assertNull(controller.holdDue(1_279L))
        val began = controller.holdDue(1_280L) as MonitorMediaSelectionController.News.Selection
        assertTrue(began.selecting)
        assertEquals(setOf("b"), began.selected)
        assertNull(controller.move("b", 10f, 12f))
        val sweep = controller.move("e", 10f, 80f) as MonitorMediaSelectionController.News.Selection
        assertEquals(setOf("b", "c", "d", "e"), sweep.selected)
        assertNull(controller.move("e", 12f, 82f))
        controller.up(false)
        assertFalse(controller.consuming)
        assertEquals(setOf("b", "c", "d", "e"), controller.selected)
    }

    @Test fun slopBeforeHoldCancelsAndDoesNotOpen() {
        val controller = MonitorMediaSelectionController()
        controller.bind(letters, false, emptySet())
        controller.down("a", 0f, 0f, 0L)
        assertNull(controller.move("a", 6f, 0f))
        assertNull(controller.holdDue(280L))
        assertNull(controller.up(false))
        assertFalse(controller.selecting)
        assertTrue(controller.selected.isEmpty())
    }

    @Test fun tapOpensWhileBrowsingAndTogglesWhileSelecting() {
        val controller = MonitorMediaSelectionController()
        controller.bind(letters, false, emptySet())
        controller.down("d", 0f, 0f, 0L)
        val open = controller.up(false) as MonitorMediaSelectionController.News.Open
        assertEquals("d", open.id)

        controller.bind(letters, true, setOf("a"))
        controller.down("a", 0f, 0f, 0L)
        val off = controller.up(false) as MonitorMediaSelectionController.News.Selection
        assertEquals(emptySet(), off.selected)
        controller.down("c", 0f, 0f, 0L)
        val on = controller.up(false) as MonitorMediaSelectionController.News.Selection
        assertEquals(setOf("c"), on.selected)
    }

    @Test fun childConsumedTapDoesNotOpenOrToggle() {
        val controller = MonitorMediaSelectionController()
        controller.bind(letters, false, emptySet())
        controller.down("a", 0f, 0f, 0L)
        assertNull(controller.up(childConsumed = true))
    }

    @Test fun selectingDragStartsFromUnselectedAndSelectedOrigins() {
        val controller = MonitorMediaSelectionController()
        controller.bind(letters, true, setOf("a", "b", "c"))
        controller.down("e", 0f, 0f, 0L)
        val select = controller.move("g", 8f, 0f) as MonitorMediaSelectionController.News.Selection
        assertEquals(setOf("a", "b", "c", "e", "f", "g"), select.selected)

        controller.cancel()
        controller.bind(letters, true, setOf("a", "b", "c", "d"))
        controller.down("b", 0f, 0f, 0L)
        val deselect = controller.move("d", 8f, 0f) as MonitorMediaSelectionController.News.Selection
        assertEquals(setOf("a"), deselect.selected)
    }

    @Test fun selectingVerticalSwipeYieldsToScrollAndLocksTheTouch() {
        val controller = MonitorMediaSelectionController()
        controller.bind(letters, true, setOf("a"))
        controller.down("a", 0f, 0f, 0L)
        assertNull(controller.move("c", 2f, 8f))
        assertTrue(controller.shouldYieldToScroll())
        assertNull(controller.move("e", 20f, 8f))
        assertFalse(controller.consuming)
        assertEquals(setOf("a"), controller.selected)
        assertNull(controller.holdDue(280L))
    }

    @Test fun holdThenVerticalSweepStaysASelectionGesture() {
        val controller = MonitorMediaSelectionController()
        controller.bind(letters, true, emptySet())
        controller.down("a", 0f, 0f, 0L)
        controller.holdDue(280L)
        val sweep = controller.move("d", 0f, 40f) as MonitorMediaSelectionController.News.Selection
        assertEquals(setOf("a", "b", "c", "d"), sweep.selected)
        assertFalse(controller.shouldYieldToScroll())
    }

    @Test fun cancelStopsConsumingAndKeepsLastPublishedSelection() {
        val controller = MonitorMediaSelectionController()
        controller.bind(letters, false, emptySet())
        controller.down("a", 0f, 0f, 0L)
        controller.holdDue(280L)
        controller.move("c", 0f, 20f)
        assertTrue(controller.consuming)
        controller.cancel()
        assertFalse(controller.consuming)
        assertEquals(setOf("a", "b", "c"), controller.selected)
        assertNull(controller.up(false))
    }

    @Test fun reorderCancelsAnActiveGesture() {
        val controller = MonitorMediaSelectionController()
        controller.bind(letters, false, emptySet())
        controller.down("a", 0f, 0f, 0L)
        controller.holdDue(280L)
        assertTrue(controller.consuming)
        controller.bind(letters.reversed(), true, controller.selected)
        assertFalse(controller.consuming)
    }

    @Test fun aViewportResizeUnderAStillSweepScrollsOnlyOnceTheFingerMoves() {
        // Swift twin: MonitorMediaDragSelectionTests.aViewportResizeUnderAStillSweepScrollsOnlyOnceThePointerMoves.
        val controller = MonitorMediaSelectionController()
        controller.bind(letters, false, emptySet())
        controller.down("a", 10f, 700f, 0L)
        controller.holdDue(280L)
        assertFalse(controller.inEdgeBand(800f), "The hold is clear of the edge of the viewport it began in")
        // The selection tray shrinks the viewport to 720: the same still finger now lies in its bottom band.
        controller.viewportResized()
        assertFalse(controller.inEdgeBand(720f))
        assertEquals(0f, controller.edgeScroll(0.1f, 720f))
        // A sideways sweep along the row keeps the edge held.
        controller.move("b", 200f, 702f)
        assertFalse(controller.inEdgeBand(720f))
        assertEquals(0f, controller.edgeScroll(0.1f, 720f))
        // The finger itself moving towards the edge arms it again.
        controller.move("b", 200f, 710f)
        assertTrue(controller.inEdgeBand(720f))
        assertTrue(controller.edgeScroll(0.1f, 720f) > 0f)
        // A new sweep starts armed: a still hold at the edge of an unchanged viewport scrolls.
        controller.up(false)
        controller.down("c", 10f, 710f, 1_000L)
        controller.holdDue(1_280L)
        assertTrue(controller.edgeScroll(0.1f, 720f) > 0f)
    }

    @Test fun stationaryEdgeTickCapsDtAndStopsRebuildingUnchangedEndpoints() {
        val controller = MonitorMediaSelectionController()
        controller.bind(letters, false, emptySet())
        controller.down("a", 10f, 800f, 0L)
        controller.holdDue(280L)
        val capped = controller.edgeScroll(0.2f, 800f)
        assertEquals(MonitorMediaSelectionPolicy.MAX_EDGE_VELOCITY * 0.05f, capped, 0.01f)
        assertNull(controller.afterScroll("a"))
        val next = controller.afterScroll("c") as MonitorMediaSelectionController.News.Selection
        assertEquals(setOf("a", "b", "c"), next.selected)
        assertNull(controller.afterScroll("c"))
        controller.move("c", 10f, 400f)
        assertEquals(0f, controller.edgeScroll(0.1f, 800f))
    }

    @Test fun hitRegistryIgnoresOffscreenCellsAndPicksNearestVisibleColumn() {
        val registry = MonitorMediaHitRegistry()
        registry.put("off", 0f, -180f, 80f, -20f)
        registry.put("left", 0f, 0f, 80f, 80f)
        registry.put("right", 90f, 0f, 170f, 80f)
        registry.put("low", 90f, 400f, 170f, 480f)
        assertEquals("left", registry.resolve(20f, 20f, 200f, 200f, nearest = false))
        assertNull(registry.resolve(20f, -40f, 200f, 200f, nearest = false))
        assertEquals("right", registry.resolve(160f, 10f, 200f, 200f, nearest = true))
        assertNull(registry.resolve(Float.NaN, 10f, 200f, 200f, nearest = true))
        registry.remove("left")
        assertEquals("right", registry.resolve(20f, 10f, 200f, 200f, nearest = true))
    }

    @Test fun fixedLinearEdgePolicyRetainsNativeBandAndBoundedSpeed() {
        val policy = MonitorMediaSelectionConfiguration(
            holdMilliseconds = 180L, movementTolerance = 40f, allowsSelectionEntry = false,
            sweepsSideways = false, edgeBand = 90f, maximumEdgeSpeed = 620f,
            edgeCurve = MonitorMediaSelectionConfiguration.EdgeCurve.LINEAR,
            viewportEdgeLimitRatio = null,
        )
        assertEquals(180L, policy.holdMilliseconds)
        assertFalse(policy.allowsSelectionEntry || policy.sweepsSideways)
        assertEquals(-310f, MonitorMediaSelectionPolicy.edgeVelocity(45f, 400f, policy))
        assertEquals(310f, MonitorMediaSelectionPolicy.edgeVelocity(355f, 400f, policy))
        assertEquals(-620f, MonitorMediaSelectionPolicy.edgeVelocity(-1f, 400f, policy))
        assertEquals(620f, MonitorMediaSelectionPolicy.edgeVelocity(401f, 400f, policy))
        assertEquals(-310f, MonitorMediaSelectionPolicy.edgeVelocity(45f, 200f, policy))
        assertEquals(0f, MonitorMediaSelectionPolicy.edgeVelocity(100f, 200f, policy))
    }

    @Test fun configuredVelocityKeepsUnknownGeometryQuietAndStandardDefaultsExact() {
        val standard = MonitorMediaSelectionConfiguration.Standard
        assertEquals(280L, standard.holdMilliseconds)
        assertEquals(5f, standard.movementTolerance)
        assertTrue(standard.allowsSelectionEntry && standard.sweepsSideways)
        for (y in listOf(-100f, 0f, 28f, 200f, 372f, 500f)) {
            assertEquals(MonitorMediaSelectionPolicy.edgeVelocity(y, 400f),
                MonitorMediaSelectionPolicy.edgeVelocity(y, 400f, standard))
        }
        assertEquals(0f, MonitorMediaSelectionPolicy.edgeVelocity(Float.POSITIVE_INFINITY, 400f, standard))
        assertEquals(0f, MonitorMediaSelectionPolicy.edgeVelocity(0f, Float.NaN, standard))
    }

    @Test fun childOwnedBrowseHoldNeverClaimsTheSameTouchAfterSelectionEntry() {
        val policy = MonitorMediaSelectionConfiguration(allowsSelectionEntry = false)
        val controller = MonitorMediaSelectionController(configuration = policy)
        controller.bind(letters, false, emptySet())
        controller.down("a", 0f, 0f, 0L)
        controller.bind(letters, true, setOf("a"))
        assertNull(controller.holdDue(280L))
        assertNull(controller.move("d", 40f, 0f))
        assertNull(controller.up(false))
        assertEquals(setOf("a"), controller.selected)
        assertFalse(controller.consuming)
        controller.down("b", 0f, 0f, 300L)
        val next = controller.holdDue(580L) as MonitorMediaSelectionController.News.Selection
        assertEquals(setOf("a", "b"), next.selected)
    }

    @Test fun nativeRoundedClockStepsKeepRateIndependentBoundAndIgnoreInvalidTime() {
        val policy = MonitorMediaSelectionConfiguration(
            edgeBand = 90f, maximumEdgeSpeed = 620f,
            edgeCurve = MonitorMediaSelectionConfiguration.EdgeCurve.LINEAR,
            viewportEdgeLimitRatio = null, roundsScrollSteps = true,
        )
        assertEquals(5f, MonitorMediaSelectionPolicy.edgeStep(400f, 400f, 1f / 120f, configuration = policy))
        assertEquals(-1f, MonitorMediaSelectionPolicy.edgeStep(-1f, 400f, 0.5f / 620f, configuration = policy))
        assertEquals(31f, MonitorMediaSelectionPolicy.edgeStep(400f, 400f, 0.2f, configuration = policy))
        assertEquals(0f, MonitorMediaSelectionPolicy.edgeStep(400f, 400f, Float.NaN, configuration = policy))
    }

    @Test fun deliberateHoldPolicyYieldsEveryPreHoldDragAndFramesStationaryEdges() {
        val policy = MonitorMediaSelectionConfiguration(
            allowsSelectionEntry = false, sweepsSideways = false, edgeBand = 72f,
            maximumEdgeSpeed = 620f, edgeCurve = MonitorMediaSelectionConfiguration.EdgeCurve.LINEAR,
            viewportEdgeLimitRatio = null,
        )
        val controller = MonitorMediaSelectionController(configuration = policy)
        controller.bind(letters, true, setOf("a"))
        controller.down("b", 0f, 0f, 0L)
        assertNull(controller.move("d", 40f, 0f))
        assertTrue(controller.shouldYieldToScroll())
        assertNull(controller.holdDue(280L))
        assertNull(controller.up(false))
        assertEquals(setOf("a"), controller.selected)

        controller.down("b", 10f, 800f, 1_000L)
        controller.holdDue(1_280L)
        assertEquals(31f, controller.edgeScroll(0.2f, 800f), 0.001f)
        assertEquals(31f, controller.edgeScroll(0.2f, 800f), 0.001f)
        val rehit = controller.afterScroll("e") as MonitorMediaSelectionController.News.Selection
        assertEquals(setOf("a", "b", "c", "d", "e"), rehit.selected)
        assertNull(controller.afterScroll("e"))
        controller.cancel()
        assertEquals(0f, controller.edgeScroll(0.2f, 800f))
        assertNull(controller.up(false))
    }

    @Test fun retiringLayoutCannotRemoveItsMountedReplacementWithTheSameId() {
        val registry = MonitorMediaHitRegistry()
        val old = Any()
        val replacement = Any()
        registry.put("volume-a/same.MOV", 0f, 0f, 80f, 80f, old)
        registry.put("volume-a/same.MOV", 90f, 0f, 170f, 80f, replacement)
        registry.put("volume-b/same.MOV", 0f, 90f, 80f, 170f, Any())
        registry.remove("volume-a/same.MOV", old)
        assertEquals("volume-a/same.MOV", registry.resolve(100f, 10f, 200f, 200f, false))
        assertEquals("volume-b/same.MOV", registry.resolve(10f, 100f, 200f, 200f, false))
        registry.remove("volume-a/same.MOV", replacement)
        assertNull(registry.resolve(100f, 10f, 200f, 200f, false))
    }

    @Test fun changedPolicyOrExternalSelectionExitRetiresAnActiveClock() {
        val controller = MonitorMediaSelectionController()
        controller.bind(letters, true, emptySet())
        controller.down("a", 10f, 800f, 0L)
        controller.holdDue(280L)
        assertTrue(controller.consuming)
        controller.configuration = MonitorMediaSelectionConfiguration(sweepsSideways = false)
        assertFalse(controller.consuming)
        assertEquals(0f, controller.edgeScroll(0.2f, 800f))
        assertNull(controller.up(false))
        controller.down("b", 10f, 800f, 1_000L)
        controller.holdDue(1_280L)
        assertTrue(controller.consuming)
        controller.bind(letters, false, controller.selected)
        assertFalse(controller.consuming)
        assertFalse(controller.selecting)
        assertEquals(0f, controller.edgeScroll(0.2f, 800f))
    }

    @Test fun replacedContextAndReorderedCatalogRejectLateHitsAndTerminalUpdates() {
        val controller = MonitorMediaSelectionController()
        controller.bind(ids, true, setOf("hidden"), context = "owner-a")
        controller.down("0", 10f, 800f, 0L)
        controller.holdDue(280L)
        controller.bind(ids, true, controller.selected, context = "owner-b")
        assertFalse(controller.consuming)
        assertNull(controller.afterScroll("4"))
        assertNull(controller.holdDue(5_000L))
        assertNull(controller.up(false))
        assertEquals(setOf("0", "hidden"), controller.selected)
        controller.down("1", 10f, 800f, 6_000L)
        controller.holdDue(6_280L)
        controller.bind(ids.reversed(), true, controller.selected, context = "owner-b")
        assertFalse(controller.consuming)
        assertNull(controller.move("5", 40f, 810f))
        assertNull(controller.afterScroll("5"))
    }

    @Test fun childConsumedTapAndMissingHitCannotOpenOrChangeAnotherSourceIdentity() {
        val distinct = listOf("volume-a/same.MOV", "volume-b/same.MOV")
        val controller = MonitorMediaSelectionController()
        controller.bind(distinct, false, emptySet())
        controller.down(distinct[0], 0f, 0f, 0L)
        assertNull(controller.up(true))
        controller.down("retired/same.MOV", 0f, 0f, 1_000L)
        assertNull(controller.holdDue(1_280L))
        assertNull(controller.up(false))
        controller.cancel()
        controller.down(distinct[1], 0f, 0f, 2_000L)
        val next = controller.holdDue(2_280L) as MonitorMediaSelectionController.News.Selection
        assertEquals(setOf(distinct[1]), next.selected)
    }
}
