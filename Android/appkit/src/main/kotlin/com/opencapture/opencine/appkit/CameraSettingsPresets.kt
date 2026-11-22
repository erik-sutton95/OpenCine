package com.opencapture.opencine.appkit

import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.CameraSettingsPreset
import com.opencapture.opencine.core.CameraSettingsPresetCodec
import com.opencapture.opencine.core.CameraSettingsPresetRecall
import com.opencapture.opencine.core.CameraSettingsPresetSkip
import com.opencapture.opencine.core.CommandDispatchAdmission
import com.opencapture.opencine.core.CommandFailure
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.UnavailableReason

/** Operator copy for exposure and white balance presets. Swift twin: `CameraSettingsPresetCopy`. */
public object CameraSettingsPresetCopy {
    public const val TITLE: String = "Camera presets"
    public const val HELP: String =
        "Save this camera's exposure and white balance, then recall them later. A recall sets only what the connected camera offers."
    public const val CONNECT_FIRST: String = "Connect a camera to save or recall its presets."
    public const val NOTHING_TO_SAVE: String = "This camera reports no exposure or white balance it can set right now."
    public const val EMPTY: String = "No presets saved for this camera model yet."

    public fun title(key: SettingKey): String = when (key) {
        SettingKey.ISO -> "ISO"
        SettingKey.SHUTTER -> "Shutter"
        SettingKey.APERTURE -> "Aperture"
        SettingKey.EXPOSURE_COMPENSATION -> "EV"
        SettingKey.WHITE_BALANCE -> "White balance"
        SettingKey.WHITE_BALANCE_TINT -> "Tint"
        else -> key.name
    }

    public fun value(value: SettingValue): String {
        if (value is SettingValue.WhiteBalanceTint) {
            // Swift prints `%g`: whole tints without a decimal point.
            val text = if (value.tint % 1.0 == 0.0) value.tint.toLong().toString() else value.tint.toString()
            return if (value.tint > 0) "+$text" else text
        }
        return MonitorCapturePresentation.label(value)
    }

    /** One line naming what a preset holds: "ISO 800 · 1/50 · WB 5600K". */
    public fun summary(preset: CameraSettingsPreset): String = preset.values.joinToString(" · ") { value ->
        when (value.key) {
            SettingKey.ISO -> "ISO ${value(value)}"
            SettingKey.EXPOSURE_COMPENSATION -> "EV ${value(value)}"
            SettingKey.WHITE_BALANCE -> "WB ${value(value)}"
            SettingKey.WHITE_BALANCE_TINT -> "Tint ${value(value)}"
            else -> value(value)
        }
    }

    public fun skip(skip: CameraSettingsPresetSkip): String = when (skip) {
        CameraSettingsPresetSkip.Unsupported -> "not offered by this camera"
        CameraSettingsPresetSkip.ReadOnly -> "read-only on this camera"
        CameraSettingsPresetSkip.OutOfDomain -> "value not offered by this camera"
        is CameraSettingsPresetSkip.Unavailable -> when (val reason = skip.reason) {
            UnavailableReason.Mode -> "not available in this mode"
            UnavailableReason.RecordingActive -> "not available while recording"
            is UnavailableReason.OtherSetting -> "needs ${title(reason.key)} first"
            else -> "not available right now"
        }
    }

    public fun failure(stage: CommandStage): String = when (stage) {
        is CommandStage.Rejected -> when (stage.rejection) {
            CommandRejection.CameraRefused -> "refused by the camera"
            CommandRejection.SessionClosed, CommandRejection.NotConnected, CommandRejection.WrongSession ->
                "camera not connected"
            CommandRejection.NoAuthority, CommandRejection.AuthorityExpired -> "no control of the camera"
            else -> "not sent"
        }
        is CommandStage.Failed -> when (stage.failure) {
            CommandFailure.NOT_APPLIED -> "not applied by the camera"
            CommandFailure.SUPERSEDED -> "replaced by a newer change"
            CommandFailure.NOT_SENT -> "not sent"
        }
        CommandStage.OutcomeUnknown -> "link dropped before it confirmed"
        else -> "not confirmed by the camera"
    }

    /** The operator's one-line result: what was recalled, what the camera skipped and what failed. */
    public fun result(recall: CameraSettingsPresetRecall): String {
        var text = "Recalled ${recall.name}."
        val skipped = recall.skipped.map { (key, skip) -> "${title(key)} (${skip(skip)})" }
        if (skipped.isNotEmpty()) text += " Skipped: ${skipped.joinToString(", ")}."
        val failed = recall.failed.map { (key, stage) -> "${title(key)} (${failure(stage)})" }
        if (failed.isNotEmpty()) text += " Not applied: ${failed.joinToString(", ")}."
        return text
    }
}

/**
 * Which presets a camera sees: one list per integration and camera model, so every body of the
 * same model shares its presets and another model never offers values it was not saved from.
 */
public object CameraSettingsPresetScope {
    /** `null` when the saved camera names no model. */
    public fun key(camera: SavedCamera): String? {
        val model = camera.model.trim()
        return if (model.isEmpty()) null else "${camera.integration.rawValue}/$model"
    }
}

/**
 * Saved presets per scope in the app's own [storage], as [CameraSettingsPresetCodec] text under
 * [prefix] plus the scope. Swift twin: `CameraSettingsPresetStore` over `UserDefaults`.
 */
public class CameraSettingsPresetStore(
    private val storage: SharedPreferences,
    private val prefix: String = "cameraSettingsPresets",
) {
    init { require(prefix.isNotEmpty()) }

    /** Bumped by every write, so a composition listing presets recomposes. */
    public var revision: Int by mutableIntStateOf(0)
        private set

    public fun presets(scope: String): List<CameraSettingsPreset> {
        @Suppress("UNUSED_VARIABLE") val observed = revision
        return storage.getString(key(scope), null)?.let(CameraSettingsPresetCodec::decode).orEmpty()
    }

    /** Adds [preset], or replaces the one with the same name (ignoring case) in place. */
    public fun save(preset: CameraSettingsPreset, scope: String) {
        val list = presets(scope).toMutableList()
        val index = list.indexOfFirst { it.name.lowercase() == preset.name.lowercase() }
        if (index >= 0) list[index] = CameraSettingsPreset(list[index].id, preset.name, preset.values)
        else list += preset
        write(list, scope)
    }

    public fun delete(id: String, scope: String) {
        write(presets(scope).filter { it.id != id }, scope)
    }

    private fun write(list: List<CameraSettingsPreset>, scope: String) {
        storage.edit().putString(key(scope), CameraSettingsPresetCodec.encode(list)).apply()
        revision++
    }

    private fun key(scope: String) = "$prefix.$scope"
}

/**
 * The presets of the shell's camera: saves its current exposure and white balance and recalls a
 * preset through the shell's common controls. [admission] supplies the host's dispatch gate for
 * each recall (a remote-control or Multiview owner), `null` to submit to the session directly.
 * Confine it to the main thread, as the controls. Swift twin: `CameraSettingsPresetsModel`.
 */
public class CameraSettingsPresetsModel(
    public val store: CameraSettingsPresetStore,
    public val shell: ShellModel,
    private val admission: () -> CommandDispatchAdmission? = { null },
) {
    private data class LastRecall(val session: CameraSessionID, val epoch: ControlEpoch, val id: String)
    private var lastRecall: LastRecall? = null

    /** A recall is in flight. */
    public var recalling: Boolean by mutableStateOf(false)
        private set

    /** The last save or recall result for the operator, `null` until there is one. */
    public var message: String? by mutableStateOf(null)
        private set

    /** The connected camera's preset list; `null` when no camera with a known model is connected. */
    public val scope: String? get() = shell.state.value.monitor?.let { CameraSettingsPresetScope.key(it.camera.saved) }

    public val presets: List<CameraSettingsPreset> get() = scope?.let { store.presets(it) }.orEmpty()

    /** Whether the camera reports something a preset could hold right now. */
    public val canSave: Boolean
        get() {
            val snapshot = shell.control.state.value.snapshot ?: return false
            return scope != null && CameraSettingsPreset.capture("", snapshot) != null
        }

    public val canRecall: Boolean
        get() = scope != null && shell.control.state.value.snapshot?.connection == ConnectionState.Ready && !recalling

    /** The name a new preset gets when the operator leaves it empty. */
    public val suggestedName: String
        get() {
            val names = presets.map { it.name.lowercase() }.toSet()
            var number = 1
            while ("preset $number" in names) number++
            return "Preset $number"
        }

    /** Saves the camera's current values under [name] (trimmed; empty takes [suggestedName]). */
    public fun save(name: String): CameraSettingsPreset? {
        val scope = scope ?: run { message = CameraSettingsPresetCopy.CONNECT_FIRST; return null }
        val chosen = name.trim().ifEmpty { suggestedName }
        val snapshot = shell.control.state.value.snapshot
        val preset = snapshot?.let { CameraSettingsPreset.capture(chosen, it) }
            ?: run { message = CameraSettingsPresetCopy.NOTHING_TO_SAVE; return null }
        store.save(preset, scope)
        message = "Saved $chosen: ${CameraSettingsPresetCopy.summary(preset)}."
        return preset
    }

    public fun delete(preset: CameraSettingsPreset) {
        val scope = scope ?: return
        store.delete(preset.id, scope)
        message = null
    }

    /** Recalls [preset] on the connected camera and reports the result in [message]. */
    public suspend fun recall(preset: CameraSettingsPreset): CameraSettingsPresetRecall? =
        recall(preset, null)

    internal suspend fun recallAdjacent(next: Boolean, admission: CommandDispatchAdmission): String {
        val list = presets
        if (list.isEmpty()) return CameraSettingsPresetCopy.EMPTY
        val snapshot = shell.control.state.value.snapshot
        val last = lastRecall?.takeIf { snapshot != null && it.session == snapshot.session && it.epoch == snapshot.epoch }
        val previous = list.indexOfFirst { it.id == last?.id }
        val index = if (previous < 0) {
            if (next) 0 else list.lastIndex
        } else {
            previous + (if (next) 1 else -1)
        }
        val preset = list.getOrNull(index)
            ?: return if (next) "Already at the last preset." else "Already at the first preset."
        val result = recall(preset, admission) ?: return "Preset recall is unavailable."
        return CameraSettingsPresetCopy.result(result)
    }

    internal suspend fun recall(preset: CameraSettingsPreset, admission: CommandDispatchAdmission?): CameraSettingsPresetRecall? {
        if (recalling) return null
        if (!canRecall) { message = CameraSettingsPresetCopy.CONNECT_FIRST; return null }
        val snapshot = shell.control.state.value.snapshot
        recalling = true
        message = "Recalling ${preset.name}..."
        val result = try {
            shell.control.recall(preset, admission ?: this.admission())
        } finally {
            recalling = false
        }
        if (snapshot != null && result.failed.isEmpty() && result.entries.any {
                it.outcome == CameraSettingsPresetRecall.Outcome.Applied ||
                    it.outcome == CameraSettingsPresetRecall.Outcome.Unchanged
            }) {
            lastRecall = LastRecall(snapshot.session, snapshot.epoch, preset.id)
        }
        message = CameraSettingsPresetCopy.result(result)
        return result
    }
}
