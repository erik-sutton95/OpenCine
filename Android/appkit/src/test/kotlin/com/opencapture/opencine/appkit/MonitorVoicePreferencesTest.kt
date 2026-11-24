package com.opencapture.opencine.appkit

import android.content.SharedPreferences
import java.lang.reflect.Proxy
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MonitorVoicePreferencesTest {
    @Test
    fun `recording toggles are independent and survive reload`() {
        val preferences = voicePreferencesStorage()
        val first = MonitorVoicePreferences(preferences)
        assertTrue(first.allows(VoiceCommand.Start))
        assertTrue(first.allows(VoiceCommand.Stop))
        first.setEnabled(MonitorVoiceAction.STOP, false)

        val reloaded = MonitorVoicePreferences(preferences)
        assertTrue(reloaded.allows(VoiceCommand.Start))
        assertFalse(reloaded.allows(VoiceCommand.Stop))
        reloaded.setEnabled(MonitorVoiceAction.STOP, true)
        assertTrue(MonitorVoicePreferences(preferences).allows(VoiceCommand.Stop))
    }

    @Test
    fun `the preset toggle applies to every supported recall phrase`() {
        val preferences = MonitorVoicePreferences(voicePreferencesStorage())
        val presetCommands = listOf(VoiceCommand.Preset(2), VoiceCommand.NextPreset, VoiceCommand.PreviousPreset)
        assertTrue(presetCommands.all(preferences::allows))
        preferences.setEnabled(MonitorVoiceAction.PRESET, false)
        assertTrue(presetCommands.none(preferences::allows))
        assertTrue(preferences.allows(VoiceCommand.Start))
        assertTrue(preferences.allows(VoiceCommand.Stop))
        assertFalse(preferences.allows(VoiceCommand.SwitchLens))
    }

    private fun voicePreferencesStorage(): SharedPreferences {
        var stored: Set<*>? = null
        val editor = Proxy.newProxyInstance(
            SharedPreferences.Editor::class.java.classLoader, arrayOf(SharedPreferences.Editor::class.java),
        ) { proxy, method, arguments ->
            when (method.name) {
                "putStringSet" -> { stored = arguments!![1] as Set<*>; proxy }
                "apply" -> null
                else -> error("Unexpected editor call: ${method.name}")
            }
        }
        return Proxy.newProxyInstance(
            SharedPreferences::class.java.classLoader, arrayOf(SharedPreferences::class.java),
        ) { _, method, arguments ->
            when (method.name) {
                "getStringSet" -> stored ?: arguments!![1]
                "edit" -> editor
                else -> error("Unexpected preferences call: ${method.name}")
            }
        } as SharedPreferences
    }
}
