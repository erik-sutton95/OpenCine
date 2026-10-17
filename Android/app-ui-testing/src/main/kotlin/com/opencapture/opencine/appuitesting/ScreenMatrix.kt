package com.opencapture.opencine.appuitesting

import com.opencapture.monitorui.ReviewLaunch
import com.opencapture.monitorui.settings.MonitorSettingsTab
import org.junit.After
import org.junit.Test

/**
 * The screenshot matrix (A7 increment 5; Swift twin `ScreenMatrix`): each key screen in light and
 * dark, portrait and landscape, with the checkpoint geometry invariants and one screenshot per cell
 * (`<app>-<device>-<orientation>-ScreenMatrix-<screen>-<appearance>.png`). The device cell (phone or
 * tablet) is the destination the run picks; the adaptive layout sweeps (V1 iOS, V2 Android) read it.
 */
@Conformance
public abstract class ScreenMatrix(subject: ConformanceApp) : ConformanceTest(subject) {
    private var wasDark: Boolean? = null

    @After
    public fun restoreAppearance() {
        wasDark?.let(::appearance)
    }

    @Test
    public fun cameras(): Unit = matrix("cameras", ReviewLaunch(ReviewLaunch.Screen.CAMERAS)) { it.info.isClickable }

    @Test
    public fun pairing(): Unit = matrix("pairing", ReviewLaunch(ReviewLaunch.Screen.PAIR)) { it.info.isClickable }

    @Test
    public fun live(): Unit = matrix("live", ReviewLaunch(ReviewLaunch.Screen.LIVE)) { it.tag == "monitor.system.record" }

    @Test
    public fun gallery(): Unit =
        matrix("gallery", ReviewLaunch(ReviewLaunch.Screen.MEDIA)) { it.tag?.startsWith(MediaGalleryProbe.CLIP) == true }

    @Test
    public fun player(): Unit =
        matrix("player", ReviewLaunch(ReviewLaunch.Screen.PLAYBACK)) { it.tag == "monitor.playback.back" }

    @Test
    public fun settings(): Unit = matrix(
        "settings", ReviewLaunch(ReviewLaunch.Screen.SETTINGS, settingsTab = MonitorSettingsTab.DISPLAY),
    ) { it.tag == "monitor.settings.tab.Display" && it.selected }

    private fun matrix(screen: String, review: ReviewLaunch, shown: (UiNode) -> Boolean) {
        if (wasDark == null) wasDark = isDark()
        val failures = mutableListOf<String>()
        for (dark in listOf(false, true)) {
            appearance(dark)
            launch(review)
            await("$screen staged", match = shown)
            for (landscape in listOf(false, true)) {
                rotate(landscape)
                // Every cell is captured even when an earlier one breaks an invariant.
                runCatching { checkpoint("$screen-${if (dark) "dark" else "light"}", safeArea = true) }
                    .onFailure { failures += it.message.orEmpty() }
            }
        }
        if (failures.isNotEmpty()) fail(failures.joinToString("\n"), dump = false)
    }
}
