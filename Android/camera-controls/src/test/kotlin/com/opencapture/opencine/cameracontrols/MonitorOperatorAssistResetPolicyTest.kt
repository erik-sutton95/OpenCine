package com.opencapture.opencine.cameracontrols

import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorWaveformMode
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.media.MonitorCrushClipCompensation
import kotlin.test.Test
import kotlin.test.assertEquals

/** A4-06: a card's reset follows the recipe's policy (iOS `MonitorOperatorAssistResetPolicy`). */
class MonitorOperatorAssistResetPolicyTest {
    @Test fun plotControlsAlsoReturnTheTrafficLightsToTheirDefaultSize() {
        for (policy in MonitorOperatorAssistResetPolicy.entries) {
            val assist = MonitorAssistState()
            assist.setCompensation(MonitorCrushClipCompensation.ONE)
            assist.setScale(MonitorAssistTool.LIGHTS, 1.4)
            assist.setWaveform(MonitorWaveformMode.LUMA, scale = 1.4)
            policy.reset(assist, MonitorAssistTool.LIGHTS)
            policy.reset(assist, MonitorAssistTool.WAVE)
            assertEquals(MonitorCrushClipCompensation.ZERO, assist.crushClipCompensation, "$policy")
            assertEquals(MonitorWaveformMode.RGB, assist.waveMode, "$policy")
            assertEquals(1.4, assist.waveScale, "$policy keeps the waveform's size")
            assertEquals(if (policy == MonitorOperatorAssistResetPolicy.PLOT_CONTROLS) 1.0 else 1.4,
                assist.lightsScale, "$policy")
        }
    }
}
