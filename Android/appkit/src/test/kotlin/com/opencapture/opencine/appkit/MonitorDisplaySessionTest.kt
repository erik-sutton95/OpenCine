package com.opencapture.opencine.appkit

import org.junit.Assert.*
import org.junit.Test

class MonitorDisplaySessionTest {
    @Test fun sourceOrderCyclesAndWraps() {
        val model = MonitorDisplaySession("live")
        assertTrue(model.cycle(listOf("live", "clean", "controls")))
        assertEquals("clean", model.mode)
        assertTrue(model.cycle(listOf("live", "clean", "controls")))
        assertEquals("controls", model.mode)
        assertTrue(model.cycle(listOf("live", "clean", "controls")))
        assertEquals("live", model.mode)
    }

    @Test fun lockRefusesCycleAndSelection() {
        val model = MonitorDisplaySession("live")
        model.locked = true
        assertFalse(model.cycle(listOf("live", "clean")))
        assertFalse(model.select("clean", listOf("live", "clean")))
        assertEquals("live", model.mode)
        model.locked = false
        assertTrue(model.select("clean", listOf("live", "clean")))
    }

    @Test fun removedSourceModeIsNeverSelected() {
        val model = MonitorDisplaySession("controls")
        assertFalse(model.select("controls", listOf("clean", "live")))
        assertTrue(model.reconcile(listOf("clean", "live")))
        assertEquals("clean", model.mode)
        assertTrue(model.cycle(listOf("clean", "live")))
        assertEquals("live", model.mode)
    }

    @Test fun disabledModeCanBeEditedAndDoneReturnsToItOnce() {
        val model = MonitorDisplaySession("live")
        model.beginEditing("clean")
        assertEquals("clean", model.mode)
        assertTrue(model.isEditing)
        assertEquals("clean", model.finishEditing(listOf("live")))
        assertEquals("clean", model.returnedMode)
        assertEquals("live", model.mode)
        assertFalse(model.isEditing)
        assertNull(model.finishEditing(listOf("live")))
    }

    @Test fun retirementClearsEditorWithoutChangingIntent() {
        val model = MonitorDisplaySession("live")
        model.beginEditing("clean")
        model.locked = true
        model.returnedMode = "controls"
        model.retireEditor()
        assertNull(model.editingMode)
        assertNull(model.returnedMode)
        assertEquals("clean", model.mode)
        assertTrue(model.locked)
    }

    @Test fun emptyAndUnknownOrdersDoNotInventMode() {
        val model = MonitorDisplaySession("picture")
        assertFalse(model.cycle(emptyList()))
        assertFalse(model.reconcile(emptyList()))
        assertEquals("picture", model.mode)
        assertNull(MonitorDisplaySession.next(emptyList(), "picture"))
        assertEquals("clean", MonitorDisplaySession.next(listOf("clean", "live"), "picture"))
    }
}
