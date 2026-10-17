package com.opencapture.monitorui

import com.opencapture.monitorui.settings.MonitorSettingsTab
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ReviewLaunchTest {
    @Test fun `every field round trips through the launch extras`() {
        val launches = listOf(
            ReviewLaunch(ReviewLaunch.Screen.LIVE),
            ReviewLaunch(
                ReviewLaunch.Screen.PLAYBACK, state = "connecting", layout = MonitorMediaLayout.LIST,
                mediaCount = 3, source = ReviewLaunch.Source.CAMERA, connected = true,
                settingsTab = MonitorSettingsTab.DISPLAY, commonControls = false, meteredEv = -2.0 / 3,
            ),
        ) + ReviewLaunch.Screen.entries.map { ReviewLaunch(it) }
        for (launch in launches) assertEquals(launch, ReviewLaunch.decode(launch.extras::get))
    }

    @Test fun `the wire uses the existing review names`() {
        val extras = ReviewLaunch(
            ReviewLaunch.Screen.CHROME_EDIT, state = "empty", layout = MonitorMediaLayout.LIST, mediaCount = 12,
            source = ReviewLaunch.Source.CAMERA, connected = true, settingsTab = MonitorSettingsTab.STORAGE,
            commonControls = false, meteredEv = -0.5,
        ).extras
        assertEquals(
            mapOf(
                "OPV_UI_REVIEW_SCREEN" to "chrome-edit", "OPV_UI_REVIEW_STATE" to "empty",
                "OPV_UI_REVIEW_MEDIA_LAYOUT" to "list", "OPV_UI_REVIEW_MEDIA_COUNT" to "12",
                "OPV_UI_REVIEW_MEDIA_SOURCE" to "camera", "OPV_UI_REVIEW_CONNECTED" to "1",
                "OPV_UI_REVIEW_SETTINGS_TAB" to "Storage", "OPV_UI_REVIEW_COMMON_CONTROLS" to "0",
                "OPV_UI_REVIEW_METERED_EV" to "-0.5",
            ),
            extras,
        )
    }

    @Test fun `absent values take the defaults`() {
        assertEquals(ReviewLaunch(ReviewLaunch.Screen.MEDIA), ReviewLaunch.decode(mapOf("OPV_UI_REVIEW_SCREEN" to "media")::get))
        assertNull(ReviewLaunch.decode(emptyMap<String, String>()::get))
    }

    @Test fun `malformed values stage nothing`() {
        for ((key, value) in listOf(
            "OPV_UI_REVIEW_SCREEN" to "media-fixture", "OPV_UI_REVIEW_SCREEN" to "",
            "OPV_UI_REVIEW_MEDIA_LAYOUT" to "tiles", "OPV_UI_REVIEW_MEDIA_COUNT" to "0",
            "OPV_UI_REVIEW_MEDIA_COUNT" to "many", "OPV_UI_REVIEW_MEDIA_SOURCE" to "cloud",
            "OPV_UI_REVIEW_CONNECTED" to "yes", "OPV_UI_REVIEW_COMMON_CONTROLS" to "true",
            "OPV_UI_REVIEW_SETTINGS_TAB" to "display", "OPV_UI_REVIEW_METERED_EV" to "14 thirds",
            "OPV_UI_REVIEW_METERED_EV" to "NaN",
        )) {
            val extras = ReviewLaunch(ReviewLaunch.Screen.MEDIA).extras + (key to value)
            assertNull(ReviewLaunch.decode(extras::get), "$key=$value")
        }
    }
}
