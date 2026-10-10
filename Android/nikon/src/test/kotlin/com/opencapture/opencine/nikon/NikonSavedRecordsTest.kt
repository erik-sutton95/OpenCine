package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.core.SavedCamerasDocument
import com.opencapture.opencine.core.SavedRoute
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * OpenZCine Android saved setups (SHELL-02 design 4, tests 1-5 and 7; Swift suite
 * `NikonSavedRecords` for the iOS records) on the golden fixture the app's own store wrote
 * (`SavedCameraRecordsFixtureTest` in OpenZCine). The store here is the shared one's load and save
 * over the core merge, so this module needs no app-shell dependency.
 */
class NikonSavedRecordsTest {
    private val golden = File(System.getProperty("opencine.fixtures"), "saved-cameras/nikon-records-v0-android.json").readText()
    private val codec = NikonSavedRecordsV0()

    /** `SavedCamerasStore`'s merge-on-load and patch-on-save, over in-memory values. */
    private class Store(var legacy: String?) {
        var document = SavedCamerasDocument()
        var legacyWrites = 0
        private val codec = NikonSavedRecordsV0()

        fun load(): List<SavedCamera> {
            legacy?.let(codec::cameras)?.let { document = document.merge(it, "records", codec.heldExtras, codec.holdsRouteTitles) }
            return document.cameras
        }

        fun save(cameras: List<SavedCamera>) {
            document = document.copy(cameras = cameras)
            codec.patched(legacy, cameras)?.let { patched ->
                legacy = patched
                legacyWrites++
                document = document.recordMirror(codec.cameras(patched).orEmpty(), "records")
            }
        }
    }

    /** The older app's own reading of one record (its `SharedPreferencesSavedCameraStore.parse`). */
    private fun hosts(json: String) = JSONArray(json).let { array -> (0 until array.length()).mapNotNull { (array.opt(it) as? JSONObject)?.optString("host") } }

    private fun objects(json: String) = JSONArray(json).let { array -> (0 until array.length()).mapNotNull { array.opt(it) as? JSONObject } }

    @Test
    fun upgradeImportsEverySetupAndLeavesLegacyAlone() {
        val store = Store(golden)
        val cameras = store.load()
        assertEquals(golden, store.legacy)
        assertEquals(listOf("name:zr_3001234", "name:zr_4005678", "name:z_8_5009999", "10.0.0.5"), cameras.map { it.id })
        assertTrue(cameras.all { it.integration == NikonOpenCineSession.INTEGRATION && it.model.isEmpty() && it.device == null })

        val a = cameras[0]
        assertTrue(a.name == "A-cam" && a.advertisedName == "ZR_3001234")
        assertEquals(
            listOf("192.168.50.23|infrastructure", "usb:3f9a2c|usb-c", "192.168.1.1|camera-access-point"),
            a.routes.map { it.key },
        )
        assertEquals(listOf(RouteKind.INFRASTRUCTURE_NETWORK, RouteKind.USB, RouteKind.CAMERA_ACCESS_POINT), a.routes.map { it.kind })
        assertEquals(listOf("Studio", null, null), a.routes.map { it.title })
        assertEquals(listOf("Studio", null, "NIKON_ZR_3001234"), a.routes.map { it.network })
        assertEquals(listOf("192.168.50.23", "usb:3f9a2c", "192.168.1.1"), a.routes.map { it.extras[NikonSavedRecordsV0.Extra.HOST] })
        assertTrue(a.preferredRoute == a.routes[0].id && a.lastConnected == 1_759_307_400_250)
        assertEquals("FAST", a.routes[2].extras[NikonSavedRecordsV0.Extra.STREAM_PRESET])
        assertEquals("LATENCY", a.routes[2].extras[NikonSavedRecordsV0.Extra.QUALITY_BIAS])
        assertTrue(a.routes.none { it.bluetooth })

        assertEquals(listOf(RouteKind.PHONE_HOTSPOT), cameras[1].routes.map { it.kind })
        assertTrue(cameras[3].name == null && cameras[3].lastConnected == null)
        assertEquals(6, store.document.legacy.getValue("records").size)
    }

    @Test
    fun migrationIsIdempotent() {
        val store = Store(golden)
        val first = store.load()
        val document = store.document
        repeat(2) { assertEquals(first, store.load()) }
        assertEquals(document, store.document)
        assertEquals(golden, store.legacy)
    }

    @Test
    fun mirrorRoundTripDecodesWithTheAppDecoder() {
        val array = JSONArray(golden)
        array.getJSONObject(0).put("future-field", JSONObject().put("kept", true))
        val store = Store(array.toString())
        val cameras = store.load().toMutableList()
        val a = cameras[0]
        cameras[0] = a.copy(
            name = "Renamed",
            routes = a.routes.filter { it.kind != RouteKind.USB }.mapIndexed { i, route -> if (i == 0) route.copy(title = "Stage") else route },
        )
        cameras[2] = cameras[2].copy(
            routes = cameras[2].routes + SavedRoute(
                key = "192.168.43.9|phone-hotspot", kind = RouteKind.PHONE_HOTSPOT, lastConnected = 1_759_307_600_000,
                extras = mapOf(NikonSavedRecordsV0.Extra.HOST to "192.168.43.9", NikonSavedRecordsV0.Extra.CAMERA_NAME to "Z_8_5009999"),
            ),
        )
        cameras.removeAt(1)
        store.save(cameras)

        val legacy = store.legacy!!
        assertEquals(listOf("192.168.1.1", "192.168.50.23", "ap:NIKON_Z8_5009999", "10.0.0.5", "192.168.43.9"), hosts(legacy))
        val records = objects(legacy)
        assertTrue(records[0].getString("custom-name") == "Renamed" && records[1].getString("custom-name") == "Renamed")
        assertEquals("FAST", records[0].getString("stream-preset"))
        assertTrue(records[1].getString("setup-name") == "Stage" && records[1].getString("network-name") == "Studio")
        assertTrue(records[0].getJSONObject("future-field").getBoolean("kept"))
        assertTrue(records[4].getString("transport") == "phone-hotspot" && records[4].getLong("last-seen-at") == 1_759_307_600_000)
        assertEquals("192.168.43.9", records[4].getString("profile-id"))
        assertTrue(!records[2].has("custom-name") && !records[3].has("custom-name"))

        val again = store.load()
        assertEquals(cameras, again)
    }

    @Test
    fun downgradeCanClearASetupName() {
        clearSetupName(oldStoreLoads = false)
    }

    @Test
    fun legacyFingerprintDoesNotHideClearedSetupName() {
        clearSetupName(oldStoreLoads = true)
    }

    private fun clearSetupName(oldStoreLoads: Boolean) {
        val store = Store(golden)
        val cameras = store.load().toMutableList()
        val index = cameras[0].routes.indexOfFirst { it.kind == RouteKind.INFRASTRUCTURE_NETWORK }
        cameras[0] = cameras[0].copy(routes = cameras[0].routes.mapIndexed { i, route -> if (i == index) route.copy(title = "Stage right") else route })
        store.save(cameras)
        val old = objects(store.legacy!!)
        val renamed = old.first { it.optString("host") == "192.168.50.23" }
        assertEquals("Stage right", renamed.optString("setup-name"))
        renamed.remove("setup-name")
        store.legacy = JSONArray(old).toString()
        if (oldStoreLoads) {
            // The prior store records the new fingerprint but retains the cleared document title.
            store.document = store.document.merge(codec.cameras(store.legacy!!)!!, "records", codec.heldExtras)
            assertEquals("Stage right", store.document.cameras[0].routes[index].title)
            // With unchanged fingerprints, repairing the title must leave all other fields alone.
            store.document = store.document.copy(cameras = store.document.cameras.mapIndexed { i, camera ->
                if (i == 0) camera.copy(name = "Document camera") else camera
            })
            cameras[0] = cameras[0].copy(name = "Document camera")
        }
        cameras[0] = cameras[0].copy(routes = cameras[0].routes.mapIndexed { i, route -> if (i == index) route.copy(title = null) else route })
        assertEquals(cameras, store.load())
        assertEquals(cameras, store.load())
    }

    @Test
    fun downgradeEditsMergeBackOnUpgrade() {
        val store = Store(golden)
        val a = store.load()[0]
        val studio = a.routes.first { it.key == "192.168.50.23|infrastructure" }

        // The older build edits through its own rules: the Studio camera moved address (the
        // profile id stays), body A gained a hotspot setup and a new name, the unnamed camera went.
        val old = JSONArray(store.legacy)
        old.getJSONObject(1).put("host", "192.168.50.40").put("last-seen-at", 1_759_307_900_000)
        old.put(
            JSONObject().put("host", "192.168.43.21").put("camera-name", "ZR_3001234").put("transport", "phone-hotspot")
                .put("last-seen-at", 1_759_307_800_000).put("custom-name", "B-cam").put("profile-id", "192.168.43.21"),
        )
        for (index in 0..2) old.getJSONObject(index).put("custom-name", "B-cam")
        old.remove(5)
        store.legacy = old.toString()

        val upgraded = store.load()
        assertEquals(listOf("name:zr_3001234", "name:zr_4005678", "name:z_8_5009999"), upgraded.map { it.id })
        val merged = upgraded[0]
        assertEquals("B-cam", merged.name)
        assertEquals(
            listOf("192.168.50.23|infrastructure", "192.168.43.21|phone-hotspot", "usb:3f9a2c|usb-c", "192.168.1.1|camera-access-point"),
            merged.routes.map { it.key },
        )
        assertTrue(merged.routes[0].id == studio.id && merged.routes[0].extras[NikonSavedRecordsV0.Extra.HOST] == "192.168.50.40")
        assertTrue(merged.routes[2].id == a.routes[1].id && merged.routes[3].id == a.routes[2].id)
    }

    /**
     * One record per setup: the app (or an older build) drops one setup of a body whose other
     * records stay byte for byte. The setup leaves the document, and a later save does not put
     * it back into the records.
     */
    @Test
    fun aSetupRemovedFromTheRecordsLeavesTheDocument() {
        val store = Store(golden)
        store.load()
        val old = JSONArray(store.legacy)
        old.remove(2) // body A's USB-C setup
        store.legacy = old.toString()

        val upgraded = store.load()
        assertEquals(listOf("192.168.50.23|infrastructure", "192.168.1.1|camera-access-point"), upgraded[0].routes.map { it.key })
        store.save(listOf(upgraded[0].copy(name = "C-cam")) + upgraded.drop(1))
        assertTrue("usb:3f9a2c" !in hosts(store.legacy!!))
    }

    @Test
    fun aBadRecordIsKeptAndSkipped() {
        val array = JSONArray(golden)
        val withBad = JSONArray().put(array.get(0)).put("not a record").apply {
            for (index in 1 until array.length()) put(array.get(index))
            put(JSONObject().put("camera-name", "No host"))
        }.toString()
        val store = Store(withBad)
        val cameras = store.load()
        assertEquals(4, cameras.size)
        assertEquals(withBad, store.legacy)

        store.save(cameras.mapIndexed { i, camera -> if (i == 1) camera.copy(name = "Hotspot cam") else camera })
        val patched = JSONArray(store.legacy)
        assertEquals(8, patched.length())
        assertEquals("not a record", patched.get(1))
        assertEquals("No host", patched.getJSONObject(7).getString("camera-name"))
        assertEquals("Hotspot cam", objects(store.legacy!!).first { it.optString("host") == "192.168.43.20" }.getString("custom-name"))
    }

    /** Design test 7 (Android has no serial): one body over USB and over Wi-Fi, a pending access-point key, a generic name, shared ids. */
    @Test
    fun setupsGroupByBodyAsTheListDoes() {
        val cameras = codec.cameras(golden)!!
        assertEquals(listOf(3, 1, 1, 1), cameras.map { it.records.size })
        assertEquals("ap:NIKON_Z8_5009999", cameras[2].camera.routes[0].extras[NikonSavedRecordsV0.Extra.HOST])
        assertEquals("NIKON_Z8_5009999", cameras[2].camera.routes[0].network)

        // An unnamed router setup is told apart by its subnet; a record rebuilt from it keeps no name.
        val unnamed = cameras.first { camera -> camera.camera.routes.any { it.extras[NikonSavedRecordsV0.Extra.HOST] == "10.0.0.5" } }.camera
        assertEquals("10.0.0.x", unnamed.routes.single().network)
        val rebuilt = JSONArray(codec.patched(null, listOf(unnamed))!!).getJSONObject(0)
        assertTrue(rebuilt.isNull("network-name") || !rebuilt.has("network-name"))

        // Two unnamed setups sharing a profile id stay two cameras, and nothing is dropped.
        val shared = JSONArray()
            .put(JSONObject().put("host", "10.0.0.7").put("camera-name", "Camera 10.0.0.7").put("transport", "infrastructure").put("profile-id", "10.0.0.7"))
            .put(JSONObject().put("host", "10.0.0.7").put("camera-name", "Camera 10.0.0.7").put("transport", "camera-access-point").put("profile-id", "10.0.0.7"))
            .toString()
        val two = codec.cameras(shared)!!.map { it.camera }
        assertEquals(listOf("10.0.0.7", "10.0.0.7#2"), two.map { it.id })
        assertNull(codec.patched(shared, two))
    }

    /** One row per body: a nickname on any setup names it, a blank one is none, a generic name groups nothing. */
    @Test
    fun aNicknameOnOneSetupNamesTheBodyAndGenericNamesStaySeparate() {
        fun record(host: String, name: String, transport: String, seen: Long) =
            JSONObject().put("host", host).put("camera-name", name).put("transport", transport).put("last-seen-at", seen)
        val records = JSONArray()
            .put(record("172.20.10.8", "ZR_6002199", "phone-hotspot", 10).put("custom-name", "A-cam"))
            .put(record("usb:zr", "ZR_6002199", "usb-c", 20))
            .put(record("10.0.0.2", "Nikon ZR", "infrastructure", 1).put("custom-name", "  "))
            .put(record("172.20.10.9", "Nikon ZR", "phone-hotspot", 2))
        val cameras = codec.cameras(records.toString())!!.map { it.camera }
        assertEquals(3, cameras.size)
        assertEquals(listOf(RouteKind.USB, RouteKind.PHONE_HOTSPOT), cameras[0].routes.map { it.kind })
        assertEquals("A-cam", cameras[0].name)
        assertEquals(listOf<String?>(null, null), cameras.drop(1).map { it.name })
    }

    @Test
    fun genericAndPlaceholderNamesIdentifyNoBody() {
        for (generic in listOf("", " Camera ", "Nikon Camera", "NIKON ZR", "Nikon Corporation ZR", "PTP-IP Camera", "Camera 192.168.1.5")) {
            assertNull(nikonAssignedName(generic), generic)
        }
        assertEquals("zr_6002199", nikonAssignedName(" ZR_6002199 "))
    }
}
