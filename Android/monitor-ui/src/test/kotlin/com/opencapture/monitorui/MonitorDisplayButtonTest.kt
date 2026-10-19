package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals

/** Behavior audit PAA-424, IA-059: a DISP tap ticks like every other chrome button, before the change. */
class MonitorDisplayButtonTest {
    @Test fun anAdmittedTapTicksBeforeItCyclesTheMode() {
        val calls = mutableListOf<String>()
        monitorDisplayClick(true, { calls += "feedback" }) { calls += "cycle" }()
        assertEquals(listOf("feedback", "cycle"), calls)
        monitorDisplayClick(false, { calls += "feedback" }) { calls += "cycle" }()
        assertEquals(listOf("feedback", "cycle"), calls)
    }

    /** ZIA-145 on Android: TalkBack has no hint slot, so the step hint follows the drum's value. */
    @Test fun theDrumSpeaksItsStepHintAfterTheValue() {
        assertEquals("5600K. Use minus 10", monitorDrumDescription("5600K", "Use minus 10"))
        assertEquals("5600K", monitorDrumDescription("5600K", null))
        assertEquals("Choose value", monitorDrumDescription("", " "))
    }
}
