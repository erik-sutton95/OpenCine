package com.opencapture.opencine.appkit

import android.content.SharedPreferences
import androidx.compose.foundation.layout.Box
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.layout
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import com.opencapture.monitorui.MonitorToolUsageState
import com.opencapture.monitorui.MultiviewArrangement
import org.json.JSONObject

/** Stable presentation values, independent of camera membership and network cleanup. */
public enum class MultiviewStageLayout(public val rawValue: String) {
    GRID("2 × 2 grid"), CENTER_STAGE("Center stage");

    public val arrangement: MultiviewArrangement
        get() = if (this == GRID) MultiviewArrangement.GRID else MultiviewArrangement.CENTER_STAGE
}

public data class MultiviewStagePreferences(
    public val layout: MultiviewStageLayout = MultiviewStageLayout.CENTER_STAGE,
    public val selected: Int = 0,
    public val fill: Boolean = false,
    public val clean: Boolean = false,
    public val toolsExpanded: Boolean = false,
    public val toolUsage: MonitorToolUsageState = MonitorToolUsageState(),
) {
    public fun encode(): String = JSONObject()
        .put("layout", layout.rawValue).put("selected", selected).put("fill", fill)
        .put("clean", clean).put("toolsExpanded", toolsExpanded)
        .put("toolUsage", encodeMonitorToolUsage(toolUsage)).toString()

    public companion object {
        public fun decode(raw: String): MultiviewStagePreferences? = try {
            val obj = JSONObject(raw)
            MultiviewStagePreferences(
                layout = if (obj.has("layout")) MultiviewStageLayout.entries.first { it.rawValue == obj.getString("layout") }
                    else MultiviewStageLayout.CENTER_STAGE,
                selected = if (obj.has("selected")) obj.getInt("selected") else 0,
                fill = if (obj.has("fill")) obj.getBoolean("fill") else false,
                clean = if (obj.has("clean")) obj.getBoolean("clean") else false,
                toolsExpanded = if (obj.has("toolsExpanded")) obj.getBoolean("toolsExpanded") else false,
                toolUsage = if (obj.has("toolUsage")) decodeMonitorToolUsage(obj.getJSONObject("toolUsage"))
                    else MonitorToolUsageState(),
            )
        } catch (_: Exception) { null }
    }
}

/** The coordinator owns this state; transient editors, popups and sessions never enter it. */
public class MultiviewStageState(private val slotCount: Int) {
    init { require(slotCount > 0) }
    public var preferences: MultiviewStagePreferences by mutableStateOf(MultiviewStagePreferences())
        private set
    private var save: ((MultiviewStagePreferences) -> Boolean)? = null
    private var hasStoredPreferences = false

    public var layout: MultiviewStageLayout
        get() = preferences.layout
        set(value) { update(preferences.copy(layout = value)) }
    public var selected: Int
        get() = preferences.selected
        set(value) { update(preferences.copy(selected = value)) }
    public var fill: Boolean
        get() = preferences.fill
        set(value) { update(preferences.copy(fill = value)) }
    public var clean: Boolean
        get() = preferences.clean
        set(value) { update(preferences.copy(clean = value)) }
    public var toolsExpanded: Boolean
        get() = preferences.toolsExpanded
        set(value) { update(preferences.copy(toolsExpanded = value)) }
    public var toolUsage: MonitorToolUsageState
        get() = preferences.toolUsage
        set(value) { update(preferences.copy(toolUsage = value)) }

    public fun attachPersistence(load: () -> MultiviewStagePreferences?, save: (MultiviewStagePreferences) -> Boolean) {
        this.save = save
        load()?.let {
            preferences = normalized(it)
            hasStoredPreferences = true
        }
    }

    /** A deployed app's old journal may seed presentation once, never overwrite a newer store. */
    public fun importLegacy(value: MultiviewStagePreferences) {
        if (!hasStoredPreferences) update(value)
    }

    private fun normalized(value: MultiviewStagePreferences): MultiviewStagePreferences =
        value.copy(selected = value.selected.coerceIn(0, slotCount - 1))

    private fun update(value: MultiviewStagePreferences) {
        val next = normalized(value)
        if (next == preferences) return
        preferences = next
        if (save?.invoke(next) == true) hasStoredPreferences = true
    }
}

/** The app supplies its existing preference domain and a presentation-only key. */
public class MultiviewStagePreferencesStore(private val storage: SharedPreferences, private val key: String) {
    init { require(key.isNotEmpty()) }
    public fun load(): MultiviewStagePreferences? = storage.getString(key, null)?.let(MultiviewStagePreferences::decode)
    public fun save(value: MultiviewStagePreferences): Boolean = storage.edit().putString(key, value.encode()).commit()
}

internal val LocalMultiviewStageState = staticCompositionLocalOf<MultiviewStageState?> { null }

/** Additive composition scope: the existing stage function and its JVM signature stay intact. */
@Composable
public fun MultiviewStageStateProvider(state: MultiviewStageState, content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalMultiviewStageState provides state, content = content)
}

public enum class MultiviewNetworkRestore {
    NONE, CAMERA_NETWORKS;
    public val closeQuestion: String
        get() = when (this) {
            NONE -> "Close Multiview? Recording continues."
            CAMERA_NETWORKS -> "Close Multiview and return cameras to their own Wi-Fi? Recording continues."
        }
    public companion object {
        public const val CLOSE_ACTION: String = "Close monitoring"
    }
}

public val LocalMultiviewStageVisible: androidx.compose.runtime.ProvidableCompositionLocal<Boolean> = staticCompositionLocalOf { true }

/** Keeps the actual stage composed and measured while a borrowed monitor covers it. */
@Composable
public fun MultiviewStageVisibility(visible: Boolean, content: @Composable () -> Unit) {
    CompositionLocalProvider(
        LocalMultiviewStageVisible provides visible,
        com.opencapture.monitorui.LocalMonitorAssistVisible provides visible,
    ) {
    Box(Modifier.then(if (visible) Modifier else Modifier.clearAndSetSemantics { })
        .layout { measurable, constraints ->
            val placeable = measurable.measure(constraints)
            layout(placeable.width, placeable.height) {
                if (visible) placeable.place(0, 0)
            }
        }) { content() }
    }
}

/** Working host adapters. Absent scope preserves legacy behavior; explicit empty scope offers no tools. */
public class MultiviewStageServices(
    public val availability: MultiviewToolAvailability,
    public val configureLUT: ((Int) -> Unit)? = null,
    /** The host derives each member's look from its reported source (Auto LUT), not an operator
     *  selection. It names the group LUT toggle; it grants no capability. */
    public val automaticLUT: Boolean = false,
)

internal val LocalMultiviewStageServices = staticCompositionLocalOf<MultiviewStageServices?> { null }

/** Adds current capability-derived services without changing the stage's existing JVM callable forms. */
@Composable
public fun MultiviewStageServicesProvider(services: MultiviewStageServices, content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalMultiviewStageServices provides services, content = content)
}
