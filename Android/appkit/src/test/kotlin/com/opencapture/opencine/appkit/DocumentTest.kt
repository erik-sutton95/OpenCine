package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.CameraDeviceID
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.RouteKind
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Swift suite `Document`: the stored document format, shared byte for byte. */
class DocumentTest {
    @Test
    fun theDocumentFormatIsShared() {
        val fixture = fixture("document-v1.json")
        val defaults = Defaults(mapOf("document" to fixture))
        val store = SavedCamerasStore(defaults.at("document")).apply { load() }
        assertTrue(defaults.writes.isEmpty())

        val a = store.cameras.first()
        assertEquals(CameraDeviceID.durable("SN-1", IntegrationID("test.cameras")), a.device)
        assertTrue(a.name == "A cam" && a.extras == mapOf("modelId" to "34"))
        assertEquals(1_759_307_200_250, a.lastConnected)
        assertEquals(listOf(RouteKind.CAMERA_ACCESS_POINT, RouteKind.INFRASTRUCTURE_NETWORK), a.routes.map { it.kind })
        assertTrue(a.preferredRoute == a.routes[1].id && a.routes[1].title == "Studio")
        assertTrue(a.routes[1].extras == mapOf("band" to "5") && a.routes[1].lastConnected == 1_759_307_200_250)
        assertTrue(store.cameras[1].routes.map { it.kind } == listOf(RouteKind.USB) && store.cameras[1].name == null)

        store.save(store.cameras)
        assertEquals(fixture, defaults.values["document"])
    }
}
