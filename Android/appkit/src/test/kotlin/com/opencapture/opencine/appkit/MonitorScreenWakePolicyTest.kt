package com.opencapture.opencine.appkit

import kotlin.test.Test
import kotlin.test.assertEquals

class MonitorScreenWakePolicyTest {
    @Test fun everyForegroundSurfaceHonorsThePreference() {
        for (enabled in listOf(false, true)) for (sceneActive in listOf(false, true)) {
            assertEquals(enabled && sceneActive, MonitorScreenWakePolicy.keepAwake(enabled, sceneActive))
        }
    }
    @Test fun sceneAndPreferenceChangesHaveOneDeduplicatedNativeOwner() {
        val requests = mutableListOf<Boolean>()
        val owner = MonitorScreenWakeOwner { requests.add(it) }
        owner.update(enabled = false, sceneActive = true)
        owner.update(enabled = false, sceneActive = true)
        owner.update(enabled = true, sceneActive = true)
        owner.update(enabled = true, sceneActive = false)
        owner.update(enabled = true, sceneActive = false)
        owner.update(enabled = true, sceneActive = true)
        owner.retire()
        owner.retire()
        assertEquals(listOf(false, true, false, true, false), requests)
        owner.update(enabled = false, sceneActive = true)
        owner.update(enabled = true, sceneActive = true)
        assertEquals(listOf(false, true, false, true, false, true), requests)
    }
}
