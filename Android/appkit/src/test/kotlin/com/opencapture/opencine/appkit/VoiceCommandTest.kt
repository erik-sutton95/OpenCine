package com.opencapture.opencine.appkit

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class VoiceCommandTest {
    @Test fun parsesCompletePhrases() {
        assertEquals(VoiceCommand.Start, VoiceCommand.parse("Camera, start!"))
        assertEquals(VoiceCommand.Start, VoiceCommand.parse("camera record"))
        assertEquals(VoiceCommand.Stop, VoiceCommand.parse("CAMERA, stop"))
        assertEquals(VoiceCommand.Preset(1), VoiceCommand.parse("Camera, preset one"))
        assertEquals(VoiceCommand.Preset(1), VoiceCommand.parse("Camera, preset 1"))
        assertEquals(VoiceCommand.Preset(2), VoiceCommand.parse("Camera, preset two"))
        assertEquals(VoiceCommand.Preset(2), VoiceCommand.parse("Camera, preset 2"))
        assertEquals(VoiceCommand.Preset(1), VoiceCommand.parse("Camera, load one"))
        assertEquals(VoiceCommand.Preset(1), VoiceCommand.parse("Camera, load 1"))
        assertEquals(VoiceCommand.Preset(2), VoiceCommand.parse("Camera, load two"))
        assertEquals(VoiceCommand.Preset(2), VoiceCommand.parse("Camera, load 2"))
        assertEquals(VoiceCommand.Preset(3), VoiceCommand.parse("Camera, load three"))
        assertEquals(VoiceCommand.Preset(3), VoiceCommand.parse("Camera, load 3"))
        assertEquals(VoiceCommand.Preset(3), VoiceCommand.parse("Camera, preset three"))
        assertEquals(VoiceCommand.Preset(3), VoiceCommand.parse("Camera, preset 3"))
        assertEquals(VoiceCommand.Preset(12), VoiceCommand.parse("Camera, load 12"))
        assertEquals(VoiceCommand.NextPreset, VoiceCommand.parse("Camera, load next"))
        assertEquals(VoiceCommand.PreviousPreset, VoiceCommand.parse("Camera, load previous"))
        assertEquals(VoiceCommand.SwitchLens, VoiceCommand.parse("camera switch lens"))
        assertEquals(VoiceCommand.SwitchLens, VoiceCommand.parse("Camera, change lens!"))
        for (rejected in listOf("stop", "camera", "don't say camera stop", "camera don't stop",
            "camera stop recording now", "camera stop camera start",
            "camera load zero", "camera load 0", "camera load -3", "camera load 3.5",
            "camera load three later", "camera load three or two",
            "load next", "camera load next please", "camera load previous later",
            "preset one", "camera preset one later", "camera preset two please", "camera present one",
            "load one", "camera load one later", "camera press it one", "camera pressed one",
            "camera press it two", "camera press it to",
            "switch lens", "change lens", "camera switch", "camera change lenses", "camera switch lens later",
            "please camera change lens", "camera switch lens camera switch lens",
            "camera wide", "camerawide", "camera tele", "camera lens 1x", "camera lens 3x",
            "camera white", "camera white balance", "camera 25 fps", "camera 60 fps",
            "Camera, twenty-five frames per second.", "Camera, ISO 800", "Camera, I S O eight hundred")) {
            assertNull(VoiceCommand.parse(rejected))
        }
    }
}
