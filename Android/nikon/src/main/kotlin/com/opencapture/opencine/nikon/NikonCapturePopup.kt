package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.vocabulary.CaptureLadder
import com.opencapture.opencine.vocabulary.CaptureLadderSetting
import com.opencapture.opencine.vocabulary.CaptureLock
import com.opencapture.opencine.vocabulary.CaptureTint
import com.opencapture.opencine.vocabulary.LadderSheetPresentation
import com.opencapture.opencine.vocabulary.LadderStep
import com.opencapture.opencine.vocabulary.LadderTab
import com.opencapture.opencine.vocabulary.LadderWrite

// Kotlin twin of Sources/OpenCineNikon/NikonCapturePopup.swift: the Nikon capture popups as the
// values the shared LadderSheet draws. Same names, rules and test cases (NikonCapturePopupTest).

/** The common setting a typed drum edits (Swift `NikonControlSetting`). */
enum class NikonControlSetting(val key: SettingKey, val control: CameraControl) {
    ISO(SettingKey.ISO, CameraControl.ISO),
    WHITE_BALANCE(SettingKey.WHITE_BALANCE, CameraControl.WHITE_BALANCE),
    SHUTTER(SettingKey.SHUTTER, CameraControl.SHUTTER),
    APERTURE(SettingKey.APERTURE, CameraControl.IRIS),
    ;

    /** The common value for a monitor label, or null outside this setting. */
    fun setting(label: String): SettingValue? = NikonOpenCineSession.settingValue(control, label)
}

/**
 * A write a Nikon ladder tab asks for. The value key is the tab's mode index; circuit switches
 * are separate so selecting a tab can change the circuit without pretending a drum value moved.
 */
sealed interface NikonLadderControl {
    data class Value(val index: Int) : NikonLadderControl
    data object BaseIso : NikonLadderControl
    data object AutoIso : NikonLadderControl
    data object StillAutoIso : NikonLadderControl
    data object ShutterMode : NikonLadderControl
    data object Tint : NikonLadderControl
}

/** How a Nikon capture popup's tabs behave. Each case is one property family on the body. */
enum class NikonCapturePopupKind {
    /** Movie ISO: R3D NE's Low and High base circuits, or Auto ISO Off and On. */
    ISO,
    /** Photo ISO: Auto (the body owns the value) and Manual. */
    STILL_ISO,
    /** Shutter angle and speed circuits. Choosing a circuit writes only the circuit. */
    SHUTTER,
    /** White balance: Kelvin, the body's presets, and the two-axis fine-tune pad. */
    WHITE_BALANCE,
    /** Recording codec, with the bit depths the body offers beside the selected codec. */
    CODEC,
    /** F-numbers the mounted lens reaches. */
    APERTURE,
    /** Release mode tab plus the two timer tabs; each tab is its own setting. */
    DRIVE,
    /** Each tab is an independent setting (focus mode, area, subject; audio; photo size). */
    INDEPENDENT_TABS,
    /** One setting; choosing a tab writes the value it lands on. */
    SETTINGS,
}

/** One tab as the body and the app's ladder table describe it. */
data class NikonLadderMode(
    /** The tab's mode index, the key its writes carry. */
    val index: Int,
    val title: String,
    val detail: String? = null,
    /** The app's ladder for the tab, used when the body advertises none. */
    val options: List<String>,
    /** The value the drum marks (a native base); empty for none. */
    val base: String = "",
    /** The body's current value on this tab; empty while unknown. */
    val current: String,
    /** The body refuses this tab now. */
    val disabled: Boolean = false,
    /** The values the body advertises for this tab, in body order; null or empty for none. */
    val advertised: List<String>? = null,
)

/**
 * Everything one Nikon capture popup shows, as values read from the session. [presentation]
 * turns it into the shared ladder sheet every app draws inside the common capture drawer.
 */
data class NikonCapturePopupState(
    val kind: NikonCapturePopupKind,
    val title: String,
    val subtitle: String,
    val modes: List<NikonLadderMode>,
    /** The body's camera value for the picker, which picks the opening tab of a plain setting. */
    val cameraValue: String = "",
    /** A tab position the opener asked for (a command tile); null opens on the body's value. */
    val seededTab: Int? = null,
    /** The body's active circuit (ISO base or Auto, shutter mode, photo Auto ISO). */
    val circuitIndex: Int? = null,
    val codec: String = "",
    val photography: Boolean = false,
    /** The body's white balance mode label; it picks the Kelvin or Preset tab. */
    val whiteBalanceMode: String? = null,
    val liveIso: Int? = null,
    val dualBaseIso: Boolean = false,
    val autoIso: Boolean = false,
    val isoCameraOwned: Boolean = false,
    val isoRecordingLocked: Boolean = false,
    val allowsManualIso: Boolean = true,
    val stillAllowsManualIso: Boolean = true,
    val shutterLockedOnCamera: Boolean = false,
    /** The fine-tune grid position (amber/blue, green/magenta), and whether the mode has a tune. */
    val tintCells: Pair<Int, Int> = 0 to 0,
    val tintAvailable: Boolean = false,
    val lensApertures: List<String> = emptyList(),
    /** The codec rows the body offers (Swift `codecRows.map(\.label)`). */
    val codecRows: List<String> = emptyList(),
    /** Bit depths behind those rows; a row with two or more offers a depth choice. */
    val codecDepths: List<CodecBitDepthOption> = emptyList(),
    val activeCodecDepth: Int? = null,
    /** The common setting a typed drum edits; null keeps label drums (demo, relay, untyped). */
    val typed: NikonControlSetting? = null,
) {
    /** The popup as the shared ladder sheet draws it. */
    val presentation: LadderSheetPresentation<NikonLadderControl>
        get() = LadderSheetPresentation(
            title = title, subtitle = subtitle, tabs = displayModes.map(::tab), initialTab = initialTab,
            lock = sheetLock, lockBanner = banner,
        )

    /**
     * The tabs in canonical display order: white balance Mode, Kelvin, Tint and
     * shutter Speed, Angle. Each tab keeps the body's mode index as its key, so only the display
     * order differs from the camera's mode numbering, and nothing stores a display position.
     */
    internal val displayModes: List<NikonLadderMode>
        get() {
            val order = when (kind) {
                NikonCapturePopupKind.WHITE_BALANCE -> listOf(PRESET_TAB, KELVIN_TAB, TINT_TAB)
                NikonCapturePopupKind.SHUTTER -> listOf("Speed", "Angle")
                else -> return modes
            }
            fun rank(mode: NikonLadderMode) = order.indexOf(mode.title).takeIf { it >= 0 } ?: order.size
            return modes.withIndex().sortedWith(compareBy({ rank(it.value) }, { it.index })).map { it.value }
        }

    /** The canonical tab label: the white balance presets tab is "Mode". */
    internal fun label(mode: NikonLadderMode): String =
        if (kind == NikonCapturePopupKind.WHITE_BALANCE && mode.title == PRESET_TAB) "Mode" else mode.title

    /**
     * The opening tab as a display position: chosen in the camera's mode order, then found in
     * [displayModes] by mode index.
     */
    internal val initialTab: Int
        get() {
            val raw = when (kind) {
                NikonCapturePopupKind.ISO, NikonCapturePopupKind.SHUTTER, NikonCapturePopupKind.STILL_ISO ->
                    circuitIndex ?: 0
                NikonCapturePopupKind.WHITE_BALANCE -> {
                    val wanted = if (whiteBalanceMode == null || whiteBalanceMode == "Color temp") KELVIN_TAB else PRESET_TAB
                    modes.indexOfFirst { it.title == wanted }.takeIf { it >= 0 } ?: 0
                }
                else -> seededTab ?: modes.indexOfFirst { cameraValue in optionsOf(it) }.takeIf { it >= 0 } ?: 0
            }
            if (modes.isEmpty()) return 0
            val chosen = modes[raw.coerceIn(0, modes.size - 1)].index
            return displayModes.indexOfFirst { it.index == chosen }.takeIf { it >= 0 } ?: 0
        }

    /**
     * Recording and a camera shutter lock freeze the whole sheet. Auto ISO locks each drum
     * instead, so the operator can still leave Auto.
     */
    internal val sheetLock: CaptureLock?
        get() = when {
            kind == NikonCapturePopupKind.SHUTTER && shutterLockedOnCamera -> CaptureLock.CAMERA_CONTROL
            kind == NikonCapturePopupKind.ISO && isoRecordingLocked -> CaptureLock.RECORDING
            else -> null
        }

    internal val banner: String?
        get() {
            when (sheetLock) {
                CaptureLock.CAMERA_CONTROL -> return "Shutter locked on camera. Hold anywhere to unlock."
                CaptureLock.RECORDING -> return "ISO is locked while recording in R3D NE"
                else -> Unit
            }
            if (kind == NikonCapturePopupKind.STILL_ISO) {
                return if (stillAllowsManualIso) {
                    "Auto ISO is on. The camera sets sensitivity. Switch to Manual to choose a value."
                } else {
                    "Manual ISO needs P, S, A, M or a U bank. The camera is setting sensitivity."
                }
            }
            if (kind != NikonCapturePopupKind.ISO || !autoIso || !isoCameraOwned) return null
            return if (allowsManualIso) {
                "Auto ISO is on. The camera sets sensitivity. Switch to Auto Off to choose a value."
            } else {
                "Manual ISO needs exposure mode M. The camera is setting sensitivity."
            }
        }

    internal fun tab(mode: NikonLadderMode): LadderTab<NikonLadderControl> {
        val options = optionsOf(mode)
        val lock = tabLock(mode)
        val kelvin = kind == NikonCapturePopupKind.WHITE_BALANCE && mode.title == KELVIN_TAB
        val (activate, apply) = activation(mode)
        return LadderTab(
            label = label(mode), key = NikonLadderControl.Value(mode.index),
            ladder = CaptureLadder(
                current = mode.current.ifEmpty { null }, values = options, marked = marked(mode), lock = lock,
            ),
            detail = mode.detail, activate = activate, applyOnActivate = apply,
            disabled = mode.disabled, setting = setting(mode, options, lock),
            tint = if (kind == NikonCapturePopupKind.WHITE_BALANCE && mode.title == TINT_TAB) {
                CaptureTint(greenMagenta = tintCells.second, amberBlue = tintCells.first, range = WhiteBalanceTint.cellRange)
            } else {
                null
            },
            values = if (kelvin) ({ landed -> WbPickerPolicy.kelvinOptions(emptyList(), landed) }) else null,
            steps = steps(kelvin),
            stepsHint = stepsHint(kelvin),
        )
    }

    internal fun tabLock(mode: NikonLadderMode): CaptureLock? = when {
        kind == NikonCapturePopupKind.WHITE_BALANCE && mode.title == TINT_TAB && !tintAvailable -> CaptureLock.AUTO
        kind == NikonCapturePopupKind.ISO && autoIso && isoCameraOwned && !isoRecordingLocked -> CaptureLock.AUTO
        kind == NikonCapturePopupKind.STILL_ISO && mode.index == 0 -> CaptureLock.AUTO
        else -> null
    }

    internal fun activation(mode: NikonLadderMode): Pair<LadderWrite<NikonLadderControl>?, Boolean> = when {
        kind == NikonCapturePopupKind.ISO && dualBaseIso ->
            LadderWrite<NikonLadderControl>(NikonLadderControl.BaseIso, if (mode.index == 1) "High" else "Low") to true
        kind == NikonCapturePopupKind.ISO && autoIso -> {
            val on = mode.index == 0
            LadderWrite<NikonLadderControl>(NikonLadderControl.AutoIso, if (on) "On" else "Off") to !on
        }
        kind == NikonCapturePopupKind.STILL_ISO -> {
            val on = mode.index == 0
            LadderWrite<NikonLadderControl>(NikonLadderControl.StillAutoIso, if (on) "On" else "Off") to !on
        }
        kind == NikonCapturePopupKind.SHUTTER ->
            LadderWrite<NikonLadderControl>(NikonLadderControl.ShutterMode, if (mode.index == 1) "Speed" else "Angle") to false
        kind == NikonCapturePopupKind.DRIVE || kind == NikonCapturePopupKind.INDEPENDENT_TABS -> null to false
        kind == NikonCapturePopupKind.WHITE_BALANCE && mode.title == TINT_TAB -> null to false
        else -> null to true
    }

    /** The drum's labels: the body's advertised set where it has one, else the app's ladder. */
    internal fun optionsOf(mode: NikonLadderMode): List<String> {
        val advertised = mode.advertised?.takeIf { it.isNotEmpty() }
        return when {
            kind == NikonCapturePopupKind.ISO -> IsoPickerPolicy.options(
                codec = codec, modeIndex = mode.index,
                includingLiveISO = if (autoIso && isoCameraOwned) liveIso?.toString() else null,
            )
            kind == NikonCapturePopupKind.STILL_ISO && mode.index == 0 -> including(liveIso?.toString(), mode.options)
            kind == NikonCapturePopupKind.APERTURE -> lensApertures.ifEmpty { mode.options }
            kind == NikonCapturePopupKind.CODEC -> codecRows.ifEmpty { mode.options }
            kind == NikonCapturePopupKind.WHITE_BALANCE && mode.title == KELVIN_TAB -> WbPickerPolicy.kelvinOptions
            kind == NikonCapturePopupKind.WHITE_BALANCE && mode.title == TINT_TAB -> emptyList()
            // R3D NE forbids automatic white balance; the codec can change after the enum landed.
            kind == NikonCapturePopupKind.WHITE_BALANCE && !photography ->
                WbPickerPolicy.whiteBalanceOptions(advertised ?: mode.options, codec)
            kind == NikonCapturePopupKind.DRIVE && mode.index == 0 ->
                advertised?.let(StillPickerLadders::driveDrumOptions) ?: mode.options
            else -> advertised ?: mode.options
        }
    }

    internal fun marked(mode: NikonLadderMode): Set<String> =
        if (kind == NikonCapturePopupKind.ISO) IsoPickerPolicy.markedValues(codec, mode.index)
        else if (mode.base.isEmpty()) emptySet() else setOf(mode.base)

    /** A typed drum where the common setting covers the tab and nothing locks it. */
    internal fun setting(mode: NikonLadderMode, options: List<String>, lock: CaptureLock?): CaptureLadderSetting? {
        val typed = typed ?: return null
        if (lock != null) return null
        if (kind == NikonCapturePopupKind.WHITE_BALANCE && mode.title in setOf(KELVIN_TAB, TINT_TAB)) return null
        return CaptureLadderSetting(typed.key, options.mapNotNull(typed::setting))
    }

    internal fun stepsHint(kelvin: Boolean): String? = when {
        kind == NikonCapturePopupKind.CODEC -> CODEC_STEPS_HINT
        kelvin -> KELVIN_STEPS_HINT
        else -> null
    }

    internal fun steps(kelvin: Boolean): ((String) -> Pair<LadderStep, LadderStep>?)? {
        if (kind == NikonCapturePopupKind.CODEC) {
            val depths = codecDepths
            val active = activeCodecDepth
            return { selected -> codecSteps(depths, selected, active) }
        }
        return if (kelvin) ({ selected -> kelvinSteps(selected) }) else null
    }

    companion object {
        const val KELVIN_STEPS_HINT: String = "Use minus 10 and plus 10 beside the selected value to fine-adjust"
        const val CODEC_STEPS_HINT: String = "Use the bit-depth buttons beside the codec to switch depth"
        const val KELVIN_TAB: String = "Kelvin"
        const val TINT_TAB: String = "Tint"
        const val PRESET_TAB: String = "Preset"

        /** The body's live pick on the photo Auto tab, so a value off the ladder still centres. */
        fun including(live: String?, ladder: List<String>): List<String> {
            if (live == null || live in ladder) return ladder
            val value = live.toIntOrNull() ?: return ladder
            val index = ladder.indexOfFirst { (it.toIntOrNull() ?: Int.MAX_VALUE) > value }.takeIf { it >= 0 } ?: ladder.size
            return ladder.toMutableList().apply { add(index, live) }
        }

        fun kelvinSteps(selected: String): Pair<LadderStep, LadderStep> {
            fun step(delta: Int, label: String, description: String): LadderStep = LadderStep(
                label = label,
                value = if (WbPickerPolicy.canFineAdjust(selected, delta)) WbPickerPolicy.fineAdjust(selected, delta) else null,
                description = description, lands = true,
            )
            val fine = WbPickerPolicy.FINE_STEP_KELVIN
            return step(-fine, "−$fine", "Decrease Kelvin by $fine") to
                step(fine, "+$fine", "Increase Kelvin by $fine")
        }

        /** The low and high depth beside a codec row that offers a choice; null otherwise. */
        fun codecSteps(depths: List<CodecBitDepthOption>, selected: String, activeDepth: Int?): Pair<LadderStep, LadderStep>? {
            val row = depths.filter { it.codec == selected }
            if (row.size < 2) return null
            fun step(depth: CodecBitDepthOption): LadderStep {
                val bits = depth.bitDepth
                return LadderStep(
                    label = depth.label, value = depth.writeValue,
                    description = "Record $selected at $bits bit",
                    selected = bits != null && activeDepth == bits, lands = false,
                )
            }
            return step(row.first()) to step(row.last())
        }
    }
}

/** The depth in bits a depth label names ("10-bit" is 10); null when it names none. */
val CodecBitDepthOption.bitDepth: Int?
    get() = label.takeWhile(Char::isDigit).toIntOrNull()
