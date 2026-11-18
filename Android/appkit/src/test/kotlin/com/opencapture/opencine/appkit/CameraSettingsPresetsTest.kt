package com.opencapture.opencine.appkit

import android.content.SharedPreferences
import com.opencapture.opencine.core.CameraSettingsPreset
import com.opencapture.opencine.core.CameraSettingsPresetRecall
import com.opencapture.opencine.core.CameraSettingsPresetRecall.Outcome
import com.opencapture.opencine.core.CameraSettingsPresetSkip
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.Rational
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.ShutterValue
import com.opencapture.opencine.core.WhiteBalanceValue
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.lunaLike
import java.lang.reflect.Proxy
import kotlinx.coroutines.async
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds

/**
 * Swift suite `CameraSettingsPresetsTests`, same method names: recalling and storing exposure and
 * white balance presets through the common controls.
 */
class CameraSettingsPresetsTest {
    private suspend fun TestScope.recall(
        preset: CameraSettingsPreset, camera: FakeCameraSession, model: MonitorControlModel,
    ): CameraSettingsPresetRecall {
        val result = async { model.recall(preset) }
        // The fake confirms each write after its report delay: move its clock until the recall ends.
        for (step in 0 until 10_000) {
            runCurrent()
            if (result.isCompleted) break
            camera.advance(100.milliseconds)
        }
        return result.await()
    }

    @Test fun recallSendsOnlyWhatTheCameraTakesAndReportsTheRest() = runTest {
        val model = MonitorControlModel(backgroundScope)
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        model.bind(camera)
        runCurrent()
        assertEquals(SettingValue.Iso(ISOValue.Manual(200)), model.state.value.snapshot?.value(SettingKey.ISO)?.value)
        // Saved on a body with tint, an iris and wider EV: this camera has none of them.
        val preset = CameraSettingsPreset(name = "Day", values = listOf(
            SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(5600)), SettingValue.WhiteBalanceTint(3.0),
            SettingValue.Iso(ISOValue.Manual(800)), SettingValue.Shutter(ShutterValue.Duration(Rational(1, 60))),
            SettingValue.Aperture(2.8), SettingValue.ExposureCompensation(Rational(3)),
        ))
        val result = recall(preset, camera, model)
        assertEquals(
            listOf(Outcome.Applied, Outcome.Skipped(CameraSettingsPresetSkip.Unsupported), Outcome.Applied,
                Outcome.Unchanged, Outcome.Skipped(CameraSettingsPresetSkip.ReadOnly),
                Outcome.Skipped(CameraSettingsPresetSkip.OutOfDomain)),
            result.entries.map { it.outcome },
        )
        assertEquals(2, camera.wire.size, "only white balance and ISO reach the camera")
        assertEquals(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(5600)), camera.snapshots.value.value(SettingKey.WHITE_BALANCE).value)
        assertEquals(SettingValue.Iso(ISOValue.Manual(800)), camera.snapshots.value.value(SettingKey.ISO).value)
        assertTrue(model.state.value.pending.isEmpty())
        assertEquals(
            "Recalled Day. Skipped: Tint (not offered by this camera), Aperture (read-only on this camera), EV (value not offered by this camera).",
            CameraSettingsPresetCopy.result(result),
        )
    }

    @Test fun recallWithoutControlSendsNothing() = runTest {
        val model = MonitorControlModel(backgroundScope)
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        camera.setAuthority(ControlAuthority.ReadOnly)
        model.bind(camera)
        runCurrent()
        val preset = CameraSettingsPreset(name = "Night", values = listOf(SettingValue.Iso(ISOValue.Manual(1600))))
        val result = recall(preset, camera, model)
        assertEquals(listOf<Outcome>(Outcome.Failed(CommandStage.Rejected(CommandRejection.NoAuthority))),
            result.entries.map { it.outcome })
        assertTrue(camera.wire.isEmpty())
        assertEquals("Recalled Night. Not applied: ISO (no control of the camera).", CameraSettingsPresetCopy.result(result))
    }

    @Test fun storeKeepsOneListPerModelAndReplacesASavedName() {
        val memory = PresetPreferencesMemory()
        val store = CameraSettingsPresetStore(memory.storage)
        store.save(CameraSettingsPreset("d", "Day", listOf(SettingValue.Iso(ISOValue.Manual(100)))), "a/One")
        store.save(CameraSettingsPreset("n", "Night", listOf(SettingValue.Iso(ISOValue.Manual(3200)))), "a/One")
        store.save(CameraSettingsPreset("x", "day", listOf(SettingValue.Iso(ISOValue.Manual(200)))), "a/One")
        assertEquals(
            listOf(
                CameraSettingsPreset("d", "day", listOf(SettingValue.Iso(ISOValue.Manual(200)))),
                CameraSettingsPreset("n", "Night", listOf(SettingValue.Iso(ISOValue.Manual(3200)))),
            ),
            store.presets("a/One"),
        )
        assertTrue(store.presets("a/Two").isEmpty())
        // A second store over the same preferences reads what the first wrote.
        CameraSettingsPresetStore(memory.storage).delete("d", "a/One")
        assertEquals(listOf("n"), store.presets("a/One").map { it.id })

        val saved = SavedCamera("1", IntegrationID("test.one"), advertisedName = "Cam", model = " Body X ")
        assertEquals("test.one/Body X", CameraSettingsPresetScope.key(saved))
        assertNull(CameraSettingsPresetScope.key(SavedCamera("2", IntegrationID("t"), advertisedName = "Cam", model = "")))
    }
}

/** Uses the real storage API; no Android host is needed. */
private class PresetPreferencesMemory {
    val values = mutableMapOf<String, String>()
    val storage: SharedPreferences = Proxy.newProxyInstance(
        SharedPreferences::class.java.classLoader, arrayOf(SharedPreferences::class.java),
    ) { _, method, arguments ->
        when (method.name) {
            "getString" -> values[arguments!![0] as String] ?: arguments[1]
            "edit" -> editor()
            else -> error("Unexpected preferences call: ${method.name}")
        }
    } as SharedPreferences

    private fun editor(): SharedPreferences.Editor {
        val changes = mutableMapOf<String, String>()
        return Proxy.newProxyInstance(
            SharedPreferences.Editor::class.java.classLoader, arrayOf(SharedPreferences.Editor::class.java),
        ) { proxy, method, arguments ->
            when (method.name) {
                "putString" -> { changes[arguments!![0] as String] = arguments[1] as String; proxy }
                "apply" -> { values.putAll(changes); null }
                else -> error("Unexpected editor call: ${method.name}")
            }
        } as SharedPreferences.Editor
    }
}
