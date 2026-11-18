package com.opencapture.opencine.appkit

import android.content.SharedPreferences
import java.lang.reflect.Proxy
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MonitorTeleprompterModelTest {
    @Test fun legacyScriptWithNoNameRestoresItsExactOfflineText() {
        val storage = PrompterPreferencesMemory()
        storage.values["script"] = "Legacy text.\nSecond paragraph."
        val model = MonitorTeleprompterModel(storage.preferences)
        assertEquals("Legacy text.\nSecond paragraph.", model.script?.text)
        assertEquals("Script", model.script?.name)
        assertFalse(model.playing)
    }

    @Test fun savedSpeedRestoresAcrossTheFullSupportedRange() {
        val storage = PrompterPreferencesMemory()
        val model = MonitorTeleprompterModel(storage.preferences)
        for (speed in listOf(10f, 28f, 100f, 300f)) {
            model.updateSpeed(speed)
            assertEquals(speed, model.speed)
            assertEquals(speed, MonitorTeleprompterModel(storage.preferences).speed)
        }
    }

    @Test fun reopeningDoesNotDecodeReadableMarkdownAgain() {
        val storage = PrompterPreferencesMemory()
        storage.values["script"] = "Say # literally and keep **these words**."
        storage.values["name"] = "presentation.md"
        storage.values["sourceUrl"] = "https://example.com/script.md"
        val model = MonitorTeleprompterModel(storage.preferences)
        assertEquals(storage.values["script"], model.script?.text)
        assertEquals("https://example.com/script.md", model.script?.sourceUrl)
    }

    @Test fun cancelledAndInvalidImportsPreserveTheSavedScript(): Unit = runBlocking {
        val storage = PrompterPreferencesMemory()
        val model = MonitorTeleprompterModel(storage.preferences)
        model.previewText("Current script")
        assertTrue(model.useCandidate())
        model.seek(90.0); model.togglePlayback(); model.pause()
        assertEquals(90.0, model.position)
        model.previewText("Replacement preview")
        assertEquals("Current script", model.script?.text)
        model.cancelImport()
        assertNull(model.candidate)
        model.previewText("   ")
        assertNotNull(model.error)
        assertEquals("Current script", model.script?.text)
        assertEquals("Current script", MonitorTeleprompterModel(storage.preferences).script?.text)
    }

    @Test fun useScriptCommitsAnOfflineCopyAndResetsPausedReading(): Unit = runBlocking {
        val model = MonitorTeleprompterModel(PrompterPreferencesMemory().preferences)
        model.previewText("First script"); assertTrue(model.useCandidate())
        model.seek(120.0); model.togglePlayback()
        model.previewText("Second script")
        assertFalse(model.playing)
        assertEquals(120.0, model.position)
        assertTrue(model.useCandidate())
        assertEquals("Second script", model.script?.text)
        assertEquals(0.0, model.position)
        assertFalse(model.playing)
    }

    @Test fun cancellingAnInflightNativeLoadPreservesTheOfflineCopy(): Unit = runBlocking {
        val model = MonitorTeleprompterModel(PrompterPreferencesMemory().preferences)
        model.previewText("Current script"); assertTrue(model.useCandidate())
        val started = CompletableDeferred<Unit>()
        val pending = launch {
            model.load {
                started.complete(Unit)
                CompletableDeferred<Unit>().await()
                com.opencapture.monitorui.TeleprompterScript("Replacement", "script.txt")
            }
        }
        started.await()
        assertTrue(model.busy)
        model.cancelImport()
        pending.join()
        assertTrue(pending.isCancelled)
        assertFalse(model.busy)
        assertNull(model.candidate)
        assertNull(model.error)
        assertEquals("Current script", model.script?.text)
    }

    @Test fun explicitSourceReloadRequiresAcceptanceAndFailuresKeepTheOfflineCopy(): Unit = runBlocking {
        val storage = PrompterPreferencesMemory()
        val model = MonitorTeleprompterModel(storage.preferences)
        val source = "https://example.com/script.md"
        model.load { com.opencapture.monitorui.TeleprompterScript("Offline script", "script.md", source) }
        assertTrue(model.useCandidate())
        val restored = MonitorTeleprompterModel(storage.preferences)
        assertEquals(source, restored.script?.sourceUrl)
        restored.load { throw IllegalStateException("Offline") }
        assertEquals("Offline script", restored.script?.text)
        assertNotNull(restored.error)
        restored.load { com.opencapture.monitorui.TeleprompterScript("Refreshed script", "script.md", source) }
        assertEquals("Offline script", restored.script?.text)
        assertEquals("Refreshed script", restored.candidate?.text)
        assertTrue(restored.useCandidate())
        assertEquals("Refreshed script", MonitorTeleprompterModel(storage.preferences).script?.text)
    }

    @Test fun acceptedCorrectionsRetainPausedReadingPosition(): Unit = runBlocking {
        val model = MonitorTeleprompterModel(PrompterPreferencesMemory().preferences)
        model.previewText("First script"); assertTrue(model.useCandidate())
        model.seek(120.0); model.togglePlayback()
        model.previewText("Corrected script", edited = true)
        assertTrue(model.useCandidate())
        assertEquals("Corrected script", model.script?.text)
        assertEquals(120.0, model.position)
        assertFalse(model.playing)
    }
}

/** Exercises the public native preference contract, with no Android process or private-state inspection. */
private class PrompterPreferencesMemory {
    val values = mutableMapOf<String, Any>()
    val preferences: SharedPreferences = Proxy.newProxyInstance(SharedPreferences::class.java.classLoader,
        arrayOf(SharedPreferences::class.java)) { _, method, args ->
        when (method.name) {
            "getString", "getFloat", "getBoolean" -> values[args!![0] as String] ?: args[1]
            "edit" -> editor()
            else -> error("Unexpected preferences call ${method.name}")
        }
    } as SharedPreferences
    private fun editor(): SharedPreferences.Editor = Proxy.newProxyInstance(SharedPreferences.Editor::class.java.classLoader,
        arrayOf(SharedPreferences.Editor::class.java)) { proxy, method, args ->
        when (method.name) {
            "putString", "putFloat", "putBoolean" -> {
                val key = args!![0] as String
                args[1]?.let { values[key] = it } ?: values.remove(key)
                proxy
            }
            "apply" -> null
            else -> error("Unexpected editor call ${method.name}")
        }
    } as SharedPreferences.Editor
}
