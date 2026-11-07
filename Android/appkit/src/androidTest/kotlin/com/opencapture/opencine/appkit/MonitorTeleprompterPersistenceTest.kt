package com.opencapture.opencine.appkit

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MonitorTeleprompterPersistenceTest {
    @Test fun reopeningRetainsTheExactScriptMetadataAndOperatorSettings(): Unit = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val namespace = "teleprompter-test-${java.util.UUID.randomUUID()}"
        val preferences = context.getSharedPreferences(namespace, Context.MODE_PRIVATE)
        try {
            val model = MonitorTeleprompterModel(preferences)
            model.previewText("First paragraph.\n\nSecond paragraph: café.")
            assertTrue(model.useCandidate())
            model.updateFontSize(54f); model.updateSpeed(28f); model.updateMirrored(true)
            model.updateBackgroundOpacity(.65f); model.updateShowsPreview(false)
            model.seek(120.0); model.togglePlayback(); model.pause()
            assertEquals(120.0, model.position)
            val restored = MonitorTeleprompterModel(context.getSharedPreferences(namespace, Context.MODE_PRIVATE))
            assertEquals(model.script, restored.script)
            assertEquals(54f, restored.fontSize); assertEquals(28f, restored.speed)
            assertTrue(restored.mirrored); assertEquals(.65f, restored.backgroundOpacity)
            assertFalse(restored.showsPreview); assertFalse(restored.playing)
            assertEquals(0.0, restored.position)
        } finally { context.deleteSharedPreferences(namespace) }
    }
}
