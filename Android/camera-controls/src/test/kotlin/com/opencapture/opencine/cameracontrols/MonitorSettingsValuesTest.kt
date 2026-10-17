package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.core.SavedRoute
import kotlin.test.Test
import kotlin.test.assertEquals

class MonitorSettingsValuesTest {
    @Test fun savedSetupsNameTheCameraNetworkWhenTheyHaveOne() {
        val ap = SavedCamera(id = "a", integration = IntegrationID("x"), name = "A cam", advertisedName = "ADV",
            model = "Model A", routes = listOf(SavedRoute(key = "wifi", kind = RouteKind.INFRASTRUCTURE_NETWORK, network = "Studio"),
                SavedRoute(key = "ap", kind = RouteKind.CAMERA_ACCESS_POINT, network = "CAM_AP")))
        val plain = SavedCamera(id = "b", integration = IntegrationID("x"), advertisedName = "B adv", model = "Model B")
        val summaries = monitorSavedCameraSummaries(listOf(ap, plain))
        assertEquals(listOf("A cam", "B adv"), summaries.map { it.name })
        assertEquals(listOf("Model A · CAM_AP", "Model B"), summaries.map { it.detail })
        assertEquals(listOf("CAM_AP", null), summaries.map { it.network })
    }

    @Test fun everyLegalPageResolvesToItsDocument() {
        val privacy = MonitorLegalDocument.Link("https://example.invalid/privacy")
        val terms = MonitorLegalDocument.Text("terms")
        val licenses = MonitorLegalDocument.Text("licenses")
        val notice = MonitorLegalDocument.Text("notice")
        val documents = MonitorLegalDocuments("APP", privacy, terms, licenses, notice)
        assertEquals(listOf(privacy, terms, licenses, notice), MonitorLegalPage.entries.map { documents[it] })
        assertEquals(listOf("Privacy", "Terms", "Licenses", "NOTICE"), MonitorLegalPage.entries.map { it.title })
    }
}
