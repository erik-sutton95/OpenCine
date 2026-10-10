package com.opencapture.monitorui

import kotlin.test.*

class MonitorFocusGestureTest {
    private fun context(generation: Long = 1, focus: Boolean? = true) = MonitorFocusGestureContext(
        MonitorFocusGeometry(MonitorRect(0f, 0f, 100f, 50f), MonitorRect(0f, 0f, 100f, 50f),
            1000, 500, generation), focusAvailable = focus)
    @Test fun geometryReplacementAndReturnCannotRebindAPendingHold() {
        val original = context(); val point = MonitorFocusPixelPoint(50f, 25f)
        val down = reduceMonitorFocusGesture(MonitorFocusGestureState.Idle, MonitorFocusGestureEvent.Down(point, 0), original)
        val retired = reduceMonitorFocusGesture(down.state, MonitorFocusGestureEvent.ContextChanged, context(2))
        val returned = reduceMonitorFocusGesture(retired.state, MonitorFocusGestureEvent.HoldTimeout(300), context(3))
        assertEquals(MonitorFocusGestureState.Idle, returned.state); assertNull(returned.action)
    }
    @Test fun cancellingAHoldDoesNotEmitFocusOrACommandOnRelease() {
        val current = context(); val point = MonitorFocusPixelPoint(50f, 25f)
        val down = reduceMonitorFocusGesture(MonitorFocusGestureState.Idle, MonitorFocusGestureEvent.Down(point, 0), current)
        val cancelled = reduceMonitorFocusGesture(down.state, MonitorFocusGestureEvent.Cancel, current)
        val released = reduceMonitorFocusGesture(cancelled.state, MonitorFocusGestureEvent.Up(point, 400), current)
        assertEquals(MonitorFocusGestureState.Idle, released.state); assertNull(released.action)
    }
    @Test fun unknownFocusStillAllowsAnExplicitDisplaySwipeWithoutInventingAnAFCommand() {
        val current = context(focus = null); val point = MonitorFocusPixelPoint(50f, 1f)
        val down = reduceMonitorFocusGesture(MonitorFocusGestureState.Idle, MonitorFocusGestureEvent.Down(point, 0), current)
        assertNull(reduceMonitorFocusGesture(down.state, MonitorFocusGestureEvent.HoldTimeout(300), current).action)
        assertEquals(MonitorFocusGestureAction.RequestDisplayMode(MonitorFocusDisplayRequest.CLEAN),
            reduceMonitorFocusGesture(down.state, MonitorFocusGestureEvent.Up(MonitorFocusPixelPoint(50f, 49f), 400), current).action)
    }
    @Test fun zeroBasedEdgesAndMirroringStayInTheDeclaredCoordinateSpace() {
        val source = context().geometry!!
        assertEquals(MonitorFocusCoordinate(999, 499), source.cameraCoordinateAt(MonitorFocusPixelPoint(100f, 50f)))
        assertEquals(MonitorFocusCoordinate(0, 499), source.copy(mirrored = true).cameraCoordinateAt(MonitorFocusPixelPoint(100f, 50f)))
        assertNull(source.cameraCoordinateAt(MonitorFocusPixelPoint(101f, 50f)))
    }

    @Test fun bothAxesInverseMapPresentedCoordinatesWithoutChangingHitBounds() {
        val source = MonitorFocusGeometry(MonitorRect(20f, 30f, 200f, 100f),
            MonitorRect(20f, 30f, 200f, 100f), 401, 201, 7)
        for (horizontal in listOf(false, true)) for (vertical in listOf(false, true)) {
            val geometry = source.copy(mirrored = horizontal, mirroredVertical = vertical)
            assertEquals(MonitorFocusCoordinate(if (horizontal) 400 else 0, if (vertical) 200 else 0),
                geometry.cameraCoordinateAt(MonitorFocusPixelPoint(20f, 30f)))
            assertEquals(MonitorFocusCoordinate(if (horizontal) 300 else 100, if (vertical) 150 else 50),
                geometry.cameraCoordinateAt(MonitorFocusPixelPoint(70f, 55f)))
            assertEquals(source.hitBounds, geometry.hitBounds)
            assertNull(geometry.cameraCoordinateAt(MonitorFocusPixelPoint(19f, 55f)))
        }
    }

    @Test fun changingEitherAxisRetiresThePointerEvenWhenTheOriginalAxesReturn() {
        val original = context()
        val source = requireNotNull(original.geometry)
        val point = MonitorFocusPixelPoint(25f, 10f)
        for ((horizontal, vertical) in listOf(true to false, false to true, true to true)) {
            val changed = original.copy(geometry = source.copy(
                mirrored = horizontal, mirroredVertical = vertical))
            assertNotEquals(source.signature, requireNotNull(changed.geometry).signature)
            val down = reduceMonitorFocusGesture(MonitorFocusGestureState.Idle,
                MonitorFocusGestureEvent.Down(point, 0), original)
            val changedLift = reduceMonitorFocusGesture(down.state,
                MonitorFocusGestureEvent.Up(point, 100), changed)
            assertNull(changedLift.action)
            val retired = reduceMonitorFocusGesture(down.state,
                MonitorFocusGestureEvent.ContextChanged, changed)
            assertEquals(MonitorFocusGestureState.Idle, retired.state)
            assertNull(reduceMonitorFocusGesture(retired.state,
                MonitorFocusGestureEvent.HoldTimeout(300), original).action)
            assertNull(reduceMonitorFocusGesture(retired.state,
                MonitorFocusGestureEvent.Up(point, 400), original).action)
        }
    }

}
