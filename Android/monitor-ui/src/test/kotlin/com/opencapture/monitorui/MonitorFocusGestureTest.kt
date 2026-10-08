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
}
