package com.opencapture.opencine.cameracontrols

import android.content.Context
import com.opencapture.monitorui.MonitorLinkHealth
import com.opencapture.opencine.vocabulary.ConnectionPhase
import com.opencapture.opencine.vocabulary.LutLookResolver
import com.opencapture.opencine.vocabulary.MediaClipFormatting
import java.io.File
import java.util.Locale

/** Live link health for the settings link tile and the FPS chip. */
object OperatorLinkHealth {
    const val TARGET_FPS = 25.0

    fun bars(
        isLive: Boolean,
        videoPackets: Int,
        hasVideoFormat: Boolean,
        measuredFps: Double = -1.0,
    ): Int {
        if (!isLive) return 0
        if (measuredFps > 0.0) {
            val score = ((measuredFps / TARGET_FPS) * 100.0).coerceIn(0.0, 100.0)
            val rounded = kotlin.math.round(score).toInt()
            if (rounded <= 0) return 1
            return ((rounded + 24) / 25).coerceIn(1, 4)
        }
        return when {
            hasVideoFormat && videoPackets > 0 -> 4
            videoPackets >= 400 -> 4
            videoPackets >= 120 -> 3
            videoPackets >= 1 -> 2
            else -> 1
        }
    }

    fun score(bars: Int): Int = MonitorLinkHealth.score(bars)

    fun caption(isLive: Boolean, bars: Int): String {
        if (!isLive) return "No live path."
        if (bars <= 0) return "Waiting for the link."
        return when (MonitorLinkHealth.band(score(bars))) {
            MonitorLinkHealth.Band.STABLE -> "Link is clean. · Stable"
            MonitorLinkHealth.Band.WATCH -> "Some loss on the link. · Watch"
            MonitorLinkHealth.Band.POOR -> "Link is weak. · Poor"
        }
    }

    @Deprecated("Use MonitorLinkMeter.compactFPS")
    fun compactFps(incoming: String): String = MonitorLinkMeter.compactFPS(incoming)

    @Deprecated("Use MonitorLinkMeter.formatMeasuredFPS")
    fun formatMeasuredFps(fps: Double): String = MonitorLinkMeter.formatMeasuredFPS(fps)

    @Deprecated("Use MonitorLinkMeter.chipLabel")
    fun fpsChipLabel(isLive: Boolean, recovering: Boolean, measuredFps: Double,
        phase: ConnectionPhase): String {
        val label = MonitorLinkMeter.chipLabel(phase, recovering, false,
            MonitorLinkMeter.compactFPS(MonitorLinkMeter.formatMeasuredFPS(measuredFps)), measuredFps)
        return if (isLive && phase == ConnectionPhase.IDLE && !recovering && measuredFps <= 0.0) "LINK" else label
    }

    fun liveTileDetail(
        isLive: Boolean,
        cameraName: String,
        fpsLabel: String,
        phaseLabel: String,
    ): String = if (isLive) "$cameraName · BLE + Wi-Fi · $fpsLabel FPS" else phaseLabel
}

fun connectionPhaseLabel(phase: ConnectionPhase, failure: String?): String =
    when (phase) {
        ConnectionPhase.IDLE -> "Idle"
        ConnectionPhase.SCANNING -> "Scanning for camera…"
        ConnectionPhase.CONNECTING_GATT -> "Connecting (Bluetooth)…"
        ConnectionPhase.PAIRING -> "Pairing…"
        ConnectionPhase.AWAITING_APPROVAL -> "Approve on the camera screen"
        ConnectionPhase.READING_WIFI_CREDS -> "Reading Wi-Fi credentials…"
        ConnectionPhase.JOINING_WIFI -> "Joining camera Wi-Fi…"
        ConnectionPhase.OPENING_DATALINK -> "Opening datalink…"
        ConnectionPhase.LIVE -> "Connected"
        ConnectionPhase.FAILED ->
            if (failure.isNullOrBlank()) "Failed" else "Failed: $failure"
    }

/** The assists a clean view can keep pinned, by stored key. */
enum class CleanPinTool(val key: String, val title: String) {
    LUT("LUT", "LUT"),
    PEAKING("PEAK", "Peaking"),
    FALSE_COLOR("FALSE", "False Color"),
    ZEBRA("ZEBRA", "Zebra"),
    WAVEFORM("WAVE", "Waveform"),
    PARADE("PARADE", "Parade"),
    HISTOGRAM("HISTO", "Histogram"),
    VECTORSCOPE("VECTOR", "Vectorscope"),
    TRAFFIC_LIGHTS("LIGHTS", "Traffic Lights"),
    ND("ND", "ND Suggestion"),
    GUIDES("GUIDES", "Guides"),
    GRID("GRID", "Grid"),
    CROSSHAIR("CROSS", "Crosshair"),
    DESQUEEZE("DESQ", "Anamorphic Desqueeze"),
    MIRROR("MIRROR", "Mirror"),
    AUDIO("AUDIO", "Audio Levels"),
}

/** The cache size line: the shared decimal byte label, "Empty" for nothing cached. */
fun formatCacheSize(bytes: Long): String = if (bytes <= 0L) "Empty" else MediaClipFormatting.byteLabel(bytes)

fun formatAppVersion(versionName: String, versionCode: Long): String = "$versionName ($versionCode)"

/** The operator setup help copy both apps show; [appName] fills the lines that name the app. */
@Suppress("PropertyName")
open class OperatorHelpCopy(appName: String) {
    val CURRENT_TRANSPORT =
        "Pocket uses Bluetooth to pair, then the camera's own Wi-Fi for HEVC. USB-C, hotspot, and HDMI capture are not in this build."
    val PHASE = "Where the BLE → Wi-Fi → datalink handshake is right now."
    val CAMERA_WIFI =
        "SSID joined for this session. The password stays in the Android Keystore on this phone."
    val SAVED_CAMERAS =
        "Pair from the home list. Settings does not start a new pair. That stays on Your cameras."
    val EDIT_VIEW = "Opens the monitor with an eye on each element you can show or hide."
    val FRAME_IO =
        "Sign in to upload clips from the share popup. Frame.io needs the internet, so the phone hops off the camera Wi‑Fi for the upload."
    val RECORD_CONFIRMATION = "Ask before starting or stopping recording to prevent mistaps."
    val SHOOTING_MODE =
        "Switch the camera between Video, Photo and the time-based modes. The camera reports " +
            "the mode back, so this follows a change made on the body itself."
    val HAPTICS =
        "Short confirmation pulses for switches, settings, and gimbal limits. A connected controller also rumbles at a stop."
    val JOYSTICK_SENSITIVITY =
        "How far a stick throw moves the gimbal, on-screen or with a connected game controller. Small throws crawl; full throw is fastest. 4 is the captured feel. 5 reaches full speed sooner; 1 is the slowest."
    val VIRTUAL_JOYSTICK_SIZE =
        "How large the on-screen stick is. Medium is the default. Large is easier to grab; Small keeps more of the picture clear."
    val VIRTUAL_JOYSTICK_INVERT_PAN =
        "Reverse left and right on the on-screen stick. Off is the default. A game controller is unchanged."
    val VIRTUAL_JOYSTICK_INVERT_TILT =
        "Reverse up and down on the on-screen stick. Off is the default. A game controller is unchanged."
    val VIRTUAL_JOYSTICK_DEADZONE =
        "Ignore small movements near the center. The default is 8%. Increase it to make the center less sensitive."
    val VIRTUAL_JOYSTICK_RESPONSE =
        "Standard keeps the current feel. Linear responds evenly. Fine makes small movements gentler."
    val GIMBAL_JOYSTICK =
        "Which analog stick pans and tilts. Left is the default. The other stick does not move the gimbal."
    val GAMEPAD =
        "A connected game controller. The selected gimbal joystick pans and tilts. Cross/A records. Circle/B recenters. Square/X is rotate-180. Triangle/Y tracks a face. L1/R1 jump zoom out/in. L2/R2 hold-to-zoom (deeper is faster). D-pad up/down ISO, left/right shutter. Unplug rests the stick. On-screen stick wins while you hold it."
    val KEEP_SCREEN_AWAKE =
        MonitorSettingsCopy.keepScreenAwake
    val HDR_DISPLAY =
        "Outdoor panel brightness, not a grade. WAVE, HISTO, PARADE, VECTOR, zebras and false color still read the decoded camera signal, so judge exposure there, not from how bright the picture looks. Screen recording drops back to a normal SDR picture so the file is not HDR-boosted. This is not the camera's HDR/HLG color mode. Off by default."
    val THEME = "Charcoal field-monitor chrome with Sky Blue accents, tuned for low reflection on set."
    val SUPPORT = "Connection, live view, controls, and troubleshooting."
    val REPORT = "Opens a public issue form on GitHub for this project."
    val REPORT_PROBLEM =
        "Tell us what happened. Technical details stay off unless you include them. You can attach up to three photos. Sending does not turn on automatic reports."
    val RELIABILITY_REPORTS = MonitorSettingsCopy.automaticReports
    val RELIABILITY_UNAVAILABLE =
        "This build cannot send automatic reports. You can still share or delete reports stored on this phone."
    val FEATURE = "Start an idea in this project's feature-request discussion."
    val SOURCE =
        "View the $appName project on GitHub. Opening this may leave the camera Wi-Fi if that is the only network."
    val LINK_HEALTH = "How healthy the camera link is right now: delivery, not radio RSSI."
    val CLEAR_CACHE =
        "Removes cached clips, thumbnails and camera indexes for every camera. Cameras reload their library when connected."
    val LUT_LOOK = "Looks apply on this phone. The file on the camera is unchanged."
    val APP_VERSION = "Current $appName build from the native project metadata."
    val LOCAL_CACHE = "Cached clips, thumbnails and camera indexes for every camera on this phone."
    val CACHE_FULL_RESOLUTION =
        "Download the original camera file when you open a clip. Off keeps only the 720p proxy to save space. Share needs the original, so connect the camera if it is not cached."
    val FEED_UPSCALER = MonitorSettingsCopy.feedUpscaler
    val FALSE_COLOR_SCALE =
        "The camera color mode selects D-Log, D-Log2, Rec.709, or HLG automatically. " +
            "CineStop paints five stops around 18% gray, read through the " +
            "camera's log curve: dark green −2, yellow-green −1, gray at 18%, light pink +1 " +
            "(skin), soft yellow +2 (upper skin limit). Red is clipped and violet is crushed; " +
            "other shadows are flat dark gray and other highlights flat light gray. " +
            "Video paints video-level IRE stripes (green 41–48, pink 61–70, red clip) " +
            "over luminance grayscale. IRE paints six video-level zones over " +
            "luminance grayscale: purple crush, blue near-black, green 18% gray, pink one " +
            "stop over, yellow near clip, red clip. On log, Video and IRE read the camera's " +
            "Rec.709 look (709) or the raw signal (LOG), set under Read. Limits paints only shadow and highlight warnings, leaving other colors untouched."
    val FALSE_COLOR_REFERENCE =
        "Show a compact color key over live view while False Color is active."
    val PEAKING_SENSITIVITY =
        "Higher sensitivity catches finer edges but can get noisy on detailed scenes."
    val PEAKING_COLOR = "Choose the edge color that stays readable over your typical scene."
    val ZEBRA_UNITS =
        "Switch between native 0-255 encoded codes and a 0-100 monitoring IRE scale."
    val ZEBRA_HIGHLIGHT =
        "High zebra warns when bright detail approaches clipping after the active log curve is compensated."
    val ZEBRA_MIDTONE =
        "Midtone zebra gives a curve-compensated reference band for faces or key subject exposure."
    val WAVEFORM_BRIGHTNESS =
        "Raise trace intensity when the waveform is hard to read in bright light."
    val PARADE_BRIGHTNESS = "Raise trace intensity when channel separation is hard to see."
    val VECTORSCOPE_ZOOM =
        "Magnifies only the chroma trace; the graticule stays at unity. The vectorscope reads the monitor image (your active LUT, or the built-in display tone map), where chroma is meaningful."
    val VECTORSCOPE_BRIGHTNESS =
        "Raise trace intensity when the chroma plot is hard to read."
    val TRAFFIC_LIGHTS_COMPENSATION =
        "Stops of crush/clip tolerance before a channel indicator glows. Shared with the histogram traffic lights."}

/**
 * The clip cache directories: the app's [mediaRoots] (per-camera folders, each keeping its `index.json`)
 * first, then the older flat caches.
 */
open class OperatorMediaCacheDirs(private val mediaRoots: (Context) -> List<File>) {
    fun candidates(context: Context): List<File> =
        mediaRoots(context) + listOf(
            File(context.filesDir, "media-cache"),
            File(context.cacheDir, "media-cache"),
        )

    fun existingDir(context: Context): File? = candidates(context).firstOrNull { it.isDirectory }

    fun byteCount(context: Context): Long {
        val dir = existingDir(context) ?: return 0L
        return dir.walkTopDown().filter { it.isFile }.sumOf { it.length() }
    }

    fun clear(context: Context) {
        val mediaRoot = mediaRoots(context).firstOrNull { it.isDirectory }
        if (mediaRoot != null) {
            mediaRoot.listFiles()?.forEach { cameraDir ->
                if (!cameraDir.isDirectory) return@forEach
                cameraDir.listFiles()?.forEach { child ->
                    if (child.name != "index.json") child.deleteRecursively()
                }
            }
            return
        }
        existingDir(context)?.listFiles()?.forEach { it.deleteRecursively() }
    }
}

fun lutLookLabel(
    selection: String,
    enabled: Boolean = true,
    colorMode: Int = -1,
    profile: com.opencapture.opencine.vocabulary.CameraLUTProfile? = null,
): String {
    val source =
        LutLookResolver.resolve(
            selection = selection,
            lutOn = true,
            colorMode = colorMode,
            profile = profile,
        )
    return LutLookResolver.statusLabel(enabled, selection, source)
}
