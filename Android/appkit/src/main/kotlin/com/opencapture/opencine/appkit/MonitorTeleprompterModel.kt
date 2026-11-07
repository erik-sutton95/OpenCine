package com.opencapture.opencine.appkit

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.monitorui.TeleprompterScript
import com.opencapture.monitorui.TeleprompterScriptImport
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** One retained script and reading position, independent of any camera or picture owner. */
public class MonitorTeleprompterModel(private val preferences: SharedPreferences) {
    /** Uses the original single-script preference namespace in this app's private storage. */
    public constructor(context: Context) : this(context.applicationContext.getSharedPreferences("teleprompter", Context.MODE_PRIVATE))

    /** The saved offline copy. Import previews never replace it until Use script. */
    public var script: TeleprompterScript? by mutableStateOf(loadScript())
        private set
    /** Whether an accepted offline script is available. */
    public val hasScript: Boolean get() = script != null
    /** Saved script text size in logical platform points. */
    public var fontSize: Float by mutableStateOf(preferences.getFloat("fontSize", 40f).coerceIn(24f, 72f))
        private set
    /** Saved scrolling speed in logical points per second. */
    public var speed: Float by mutableStateOf(preferences.getFloat("speed", 36f).coerceIn(10f, 300f))
        private set
    /** Mirrors the script text without flipping the camera picture. */
    public var mirrored: Boolean by mutableStateOf(preferences.getBoolean("mirrored", false))
        private set
    /** Opacity of the black reading plate; text remains fully opaque. */
    public var backgroundOpacity: Float by mutableStateOf(preferences.getFloat("backgroundOpacity", .4f).coerceIn(0f, 1f))
        private set
    /** Shows the retained live picture behind the reading plate. */
    public var showsPreview: Boolean by mutableStateOf(preferences.getBoolean("showsPreview", true))
        private set
    /** Playback is transient: hiding the reader pauses without losing its position. */
    public var playing: Boolean by mutableStateOf(false)
        private set
    /** Transient reading offset in logical points, retained across overlay coverage. */
    public var position: Double by mutableDoubleStateOf(0.0)
        private set
    /** A separate validated preview awaiting the operator's Use script action. */
    public var candidate: TeleprompterScript? by mutableStateOf(null)
        private set
    /** Whether a native import is still in progress. */
    public var busy: Boolean by mutableStateOf(false)
        private set
    /** The last import failure; the accepted script is unchanged. */
    public var error: String? by mutableStateOf(null)
        private set
    private var operation = 0L
    private var importJob: Job? = null
    private var candidateKeepsPosition = false

    /** Validates pasted or edited text into a separate preview. */
    public suspend fun previewText(text: String, edited: Boolean = false): Unit = preview(keepPosition = edited) {
        withContext(Dispatchers.Default) {
            val imported = TeleprompterScriptImport.paste(text)
            if (edited) imported.copy(name = script?.name ?: imported.name, sourceUrl = script?.sourceUrl) else imported
        }
    }

    /** Previews a cancellable native load without replacing the saved offline script. */
    public suspend fun load(load: suspend () -> TeleprompterScript): Unit = preview(load = load)

    /** Commits only the explicitly previewed script and starts it paused at the beginning. */
    public fun useCandidate(): Boolean {
        val next = candidate ?: return false
        script = next
        candidate = null
        if (candidateKeepsPosition) pause() else reset()
        candidateKeepsPosition = false
        preferences.edit().putString("script", next.text).putString("name", next.name)
            .putString("sourceUrl", next.sourceUrl).apply()
        return true
    }

    /** Cancels in-flight import and retires its callbacks, leaving the current script intact. */
    public fun cancelImport(): Unit {
        operation++
        importJob?.cancel()
        importJob = null
        candidate = null
        candidateKeepsPosition = false
        busy = false
        error = null
    }

    /** Pauses reading without changing its offset. */
    public fun pause(): Unit { playing = false }
    /** Explicitly starts or pauses an accepted script. */
    public fun togglePlayback(): Unit { if (hasScript) playing = !playing }
    /** Pauses and returns the reader to its beginning. */
    public fun reset(): Unit { pause(); position = 0.0 }
    /** Stores a finite, nonnegative reading position. */
    public fun seek(value: Double): Unit { if (value.isFinite()) position = value.coerceAtLeast(0.0) }
    /** Saves text size and pauses before the reader relays out. */
    public fun updateFontSize(value: Float): Unit { pause(); fontSize = value.coerceIn(24f, 72f); saveOptions() }
    /** Saves the operator's scrolling speed. */
    public fun updateSpeed(value: Float): Unit { speed = value.coerceIn(10f, 300f); saveOptions() }
    /** Saves the text-only mirror setting. */
    public fun updateMirrored(value: Boolean): Unit { mirrored = value; saveOptions() }
    /** Saves the reading plate opacity. */
    public fun updateBackgroundOpacity(value: Float): Unit { backgroundOpacity = value.coerceIn(0f, 1f); saveOptions() }
    /** Saves live-picture versus text-only presentation. */
    public fun updateShowsPreview(value: Boolean): Unit { showsPreview = value; saveOptions() }

    private suspend fun preview(keepPosition: Boolean = false, load: suspend () -> TeleprompterScript) {
        cancelImport()
        pause()
        val request = operation
        importJob = currentCoroutineContext()[Job]
        busy = true
        try {
            val next = load()
            currentCoroutineContext().ensureActive()
            if (request == operation) {
                candidate = next
                candidateKeepsPosition = keepPosition
            }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) {
            if (request == operation) error = failure.message ?: "The script could not be loaded."
        } finally {
            if (request == operation) { busy = false; importJob = null }
        }
    }

    private fun loadScript(): TeleprompterScript? {
        val text = preferences.getString("script", null)?.takeIf { it.isNotBlank() } ?: return null
        return TeleprompterScript(text, preferences.getString("name", "Script") ?: "Script",
            preferences.getString("sourceUrl", null))
    }

    private fun saveOptions() {
        preferences.edit().putFloat("fontSize", fontSize).putFloat("speed", speed).putBoolean("mirrored", mirrored)
            .putFloat("backgroundOpacity", backgroundOpacity).putBoolean("showsPreview", showsPreview).apply()
    }
}
