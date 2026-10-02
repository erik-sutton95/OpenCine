package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.CameraDeviceID
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.core.SavedRoute
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

private val integration = IntegrationID("test.cameras")

internal fun fixture(name: String): String = File(System.getProperty("opencine.fixtures"), "saved-cameras/$name").readText()

internal enum class Flavor(val file: String, val dates: BodyRecordsV0.Dates, val ids: List<String>) {
    SECONDS_SINCE_2001(
        "body-records-v0-seconds-2001.json", BodyRecordsV0.Dates.SECONDS_SINCE_2001,
        listOf("6F9619FF-8B86-D011-B42D-00C04FC964FF", "7A1B2C3D-4E5F-4061-8293-A4B5C6D7E8F9", "0D1E2F30-4152-4637-8899-AABBCCDDEEFF"),
    ),
    EPOCH_MILLISECONDS(
        "body-records-v0-epoch-ms.json", BodyRecordsV0.Dates.EPOCH_MILLISECONDS,
        listOf("AA:BB:CC:DD:EE:01", "AA:BB:CC:DD:EE:02", "AA:BB:CC:DD:EE:03"),
    ),
    ;

    val fixture: String get() = fixture(file)
    val codec: BodyRecordsV0 get() = BodyRecordsV0(integration, dates)
}

/**
 * Swift suite `Migration` (SHELL-02 design 4, tests 1-6), same method names. Each test runs both
 * date flavors; the downgrade tests use the older Android builds' own codec.
 */
class MigrationTest {
    private fun store(defaults: Defaults, flavor: Flavor) =
        SavedCamerasStore(defaults.at("document"), SavedCamerasStore.Legacy(defaults.at("legacy"), flavor.codec, "records"))

    private fun upgraded(flavor: Flavor): Pair<Defaults, SavedCamerasStore> {
        val defaults = Defaults(mapOf("legacy" to flavor.fixture))
        return defaults to store(defaults, flavor).apply { load() }
    }

    @Test
    fun upgradeImportsEveryCameraAndLeavesLegacyAlone() = forEachFlavor { flavor ->
        val (defaults, store) = upgraded(flavor)
        assertEquals(flavor.fixture, defaults.values["legacy"])
        assertEquals(listOf("document"), defaults.writes)
        assertEquals(flavor.ids, store.cameras.map { it.id })
        assertTrue(store.cameras.all { it.integration == integration && it.device == null })

        val a = store.cameras[0]
        assertTrue(a.name == "A cam" && a.advertisedName == "CAM-AAAA" && a.model == "Test Body")
        assertEquals(listOf("ap", "wifi"), a.routes.map { it.key })
        assertEquals(listOf(RouteKind.CAMERA_ACCESS_POINT, RouteKind.INFRASTRUCTURE_NETWORK), a.routes.map { it.kind })
        assertEquals(listOf("CAM-AAAA", "studio"), a.routes.map { it.network })
        assertTrue(a.routes.all { it.bluetooth })
        assertEquals(a.routes[1].id, a.preferredRoute)
        assertEquals(1_759_307_200_250, a.lastConnected)
        assertEquals(if (flavor == Flavor.SECONDS_SINCE_2001) mapOf("modelId" to "34") else emptyMap(), a.extras)

        // `lastSetup` names a setup that is gone: kept verbatim, no preferred route.
        val b = store.cameras[1]
        assertTrue(b.name == null && b.model == "Test Body Mini")
        assertEquals(listOf("ap", "hotspot"), b.routes.map { it.key })
        assertEquals(listOf(null, "phone"), b.routes.map { it.network })
        assertTrue(b.preferredRoute == null && b.extras == mapOf("lastSetup" to "wifi"))
        assertEquals(1_758_307_200_000, b.lastConnected)

        val c = store.cameras[2]
        assertTrue(c.routes.map { it.key } == listOf("ap") && c.routes[0].network == null)
        assertEquals(1_757_307_200_500, c.lastConnected)

        val document = DocumentJson.decode(defaults.values.getValue("document"))
        assertTrue(document.version == 1 && document.cameras == store.cameras)
        assertEquals(flavor.ids.sorted(), document.legacy["records"]?.keys?.sorted())
    }

    @Test
    fun migrationIsIdempotent() = forEachFlavor { flavor ->
        val (defaults, first) = upgraded(flavor)
        val document = defaults.values["document"]
        repeat(2) {
            val again = store(defaults, flavor).apply { load() }
            assertEquals(first.cameras, again.cameras)
        }
        assertEquals(document, defaults.values["document"])
        assertEquals(flavor.fixture, defaults.values["legacy"])
        assertEquals(listOf("document"), defaults.writes)
    }

    @Test
    fun mirrorRoundTripDecodesWithTheOldDecoder() {
        val (defaults, store) = upgraded(Flavor.EPOCH_MILLISECONDS)
        val cameras = store.cameras.toMutableList()
        cameras[0] = cameras[0].copy(
            name = "Renamed",
            routes = cameras[0].routes + SavedRoute(key = "hotspot", kind = RouteKind.PHONE_HOTSPOT, network = "phone-2", bluetooth = true),
        )
        cameras[1] = cameras[1].copy(lastConnected = 1_760_000_000_000, preferredRoute = cameras[1].routes[0].id)
        cameras.removeAt(2)
        val added = SavedCamera(
            id = "AA:BB:CC:DD:EE:04", integration = integration, advertisedName = "CAM-DDDD", model = "Test Body",
            routes = listOf(SavedRoute(key = "ap", kind = RouteKind.CAMERA_ACCESS_POINT, bluetooth = true)),
            lastConnected = 1_760_000_001_000,
        )
        store.save(cameras + added)

        val legacy = defaults.values.getValue("legacy")
        val old = OldRecords.decode(legacy)
        val ids = Flavor.EPOCH_MILLISECONDS.ids
        assertEquals(listOf(ids[0], ids[1], added.id), old.map { it.id })
        assertTrue(old[0].customName == "Renamed" && old[0].hotspotSSID == "phone-2")
        assertTrue(old[0].wifiSSID == "studio" && old[0].lastSetup == "wifi")
        assertTrue(old[1].lastSetup == "cameraWiFi" && old[1].lastConnectedAt == 1_760_000_000_000)
        assertTrue(old[2].advertisedName == "CAM-DDDD" && old[2].lastSSID == null && old[2].customName == null)
        assertEquals(true, JSONArray(legacy).getJSONObject(1).getJSONObject("futureField").getBoolean("kept"))

        // The mirror is the new merge base: a reload keeps the document as saved.
        val again = store(defaults, Flavor.EPOCH_MILLISECONDS).apply { load() }
        assertEquals(store.cameras, again.cameras)
        assertEquals(legacy, defaults.values["legacy"])
    }

    @Test
    fun downgradeEditsMergeBackOnUpgrade() {
        val (defaults, store) = upgraded(Flavor.EPOCH_MILLISECONDS)
        val cameras = store.cameras.toMutableList()
        cameras[0] = cameras[0].copy(
            device = CameraDeviceID.durable("SN-1", integration),
            routes = cameras[0].routes.mapIndexed { index, route -> if (index == 1) route.copy(title = "Studio") else route },
        )
        store.save(cameras)
        val routeIDs = cameras[0].routes.map { it.id }

        // The older build edits through its own codec.
        val old = OldRecords.decode(defaults.values.getValue("legacy")).toMutableList()
        old[0] = old[0].copy(customName = "Old rename", hotspotSSID = "phone-3", lastSetup = "phoneHotspot")
        old[2] = old[2].copy(wifiSSID = "office")
        old.removeAt(1)
        old += OldRecords.Record("AA:BB:CC:DD:EE:05", "CAM-EEEE", "Test Body", null, 1_760_000_002_000)
        defaults.values["legacy"] = OldRecords.encode(old)

        val upgraded = store(defaults, Flavor.EPOCH_MILLISECONDS).apply { load() }
        val ids = Flavor.EPOCH_MILLISECONDS.ids
        assertEquals(listOf(ids[0], ids[2], "AA:BB:CC:DD:EE:05"), upgraded.cameras.map { it.id })
        val a = upgraded.cameras[0]
        assertTrue(a.name == "Old rename" && a.device == CameraDeviceID.durable("SN-1", integration))
        assertEquals(listOf("ap", "wifi", "hotspot"), a.routes.map { it.key })
        assertEquals("phone-3", a.routes[2].network)
        assertTrue(a.routes.map { it.id }.take(2) == routeIDs && a.routes[1].title == "Studio")
        assertEquals(a.routes[2].id, a.preferredRoute)
        assertEquals(listOf(null, "office"), upgraded.cameras[1].routes.map { it.network })
        assertEquals("CAM-EEEE", upgraded.cameras[2].advertisedName)
    }

    @Test
    fun aBadRecordIsKeptAndSkipped() = forEachFlavor { flavor ->
        val array = JSONArray(flavor.fixture)
        val withBad = JSONArray().put(array.get(0)).put("not a record").put(array.get(1)).put(array.get(2))
            .put(JSONObject().put("advertisedName", "No id"))
        val legacy = withBad.toString()
        val defaults = Defaults(mapOf("legacy" to legacy))
        val store = store(defaults, flavor).apply { load() }
        assertEquals(flavor.ids, store.cameras.map { it.id })
        assertEquals(legacy, defaults.values["legacy"])

        store.save(store.cameras.mapIndexed { index, camera -> if (index == 0) camera.copy(name = "Renamed") else camera })
        val patched = JSONArray(defaults.values.getValue("legacy"))
        assertEquals(5, patched.length())
        assertEquals("not a record", patched.get(1))
        assertEquals("No id", patched.getJSONObject(4).getString("advertisedName"))
        assertEquals("Renamed", patched.getJSONObject(0).getString("customName"))
    }

    @Test
    fun aFutureDocumentIsNeverWritten() = forEachFlavor { flavor ->
        // The document an upgrade wrote, kept to stand in for a later build's merge.
        val (earlier, _) = upgraded(flavor)
        val future = """{"version":2,"shape":"unknown"}"""
        val defaults = Defaults(mapOf("document" to future, "legacy" to flavor.fixture))
        val store = store(defaults, flavor).apply { load() }
        assertFalse(store.writesDocument)
        assertEquals(flavor.ids, store.cameras.map { it.id })
        store.save(store.cameras.mapIndexed { index, camera -> if (index == 2) camera.copy(name = "Edited while newer") else camera })
        assertEquals(future, defaults.values["document"])
        assertEquals(listOf("legacy"), defaults.writes)

        // A build that merges again sees the edit.
        defaults.values["document"] = earlier.values.getValue("document")
        val later = store(defaults, flavor).apply { load() }
        assertEquals("Edited while newer", later.cameras[2].name)
    }

    @Test
    fun nothingStoredStartsEmptyAndWritesNoLegacy() {
        val defaults = Defaults(emptyMap())
        val store = store(defaults, Flavor.EPOCH_MILLISECONDS).apply { load() }
        assertTrue(store.cameras.isEmpty())
        assertNull(defaults.values["legacy"])
    }

    private fun forEachFlavor(body: (Flavor) -> Unit) {
        for (flavor in Flavor.entries) {
            try {
                body(flavor)
            } catch (failure: AssertionError) {
                throw AssertionError("$flavor: ${failure.message}", failure)
            }
        }
    }
}

/** In-memory preferences that log which keys were written. */
internal class Defaults(values: Map<String, String>) {
    val values = values.toMutableMap()
    val writes = mutableListOf<String>()

    fun at(key: String) = object : StoredString {
        override fun read(): String? = values[key]
        override fun write(value: String) {
            values[key] = value
            writes += key
        }
    }
}

/** The per-body record codec of the older Android builds (their `SharedPreferencesSavedCameraStore`). */
internal object OldRecords {
    data class Record(
        val id: String,
        val advertisedName: String,
        val modelName: String,
        val lastSSID: String?,
        val lastConnectedAt: Long,
        val customName: String? = null,
        val wifiSSID: String? = null,
        val hotspotSSID: String? = null,
        val lastSetup: String? = null,
    )

    fun encode(records: List<Record>): String {
        val array = JSONArray()
        for (record in records) {
            array.put(
                JSONObject().apply {
                    put("id", record.id)
                    put("advertisedName", record.advertisedName)
                    put("modelName", record.modelName)
                    if (record.lastSSID != null) put("lastSSID", record.lastSSID)
                    put("lastConnectedAt", record.lastConnectedAt)
                    if (record.customName != null) put("customName", record.customName)
                    if (record.wifiSSID != null) put("wifiSSID", record.wifiSSID)
                    if (record.hotspotSSID != null) put("hotspotSSID", record.hotspotSSID)
                    if (record.lastSetup != null) put("lastSetup", record.lastSetup)
                },
            )
        }
        return array.toString()
    }

    fun decode(raw: String): List<Record> {
        val array = JSONArray(raw)
        val out = mutableListOf<Record>()
        for (i in 0 until array.length()) {
            val obj = array.getJSONObject(i)
            val id = obj.optString("id")
            if (id.isEmpty()) continue
            out.add(
                Record(
                    id = id,
                    advertisedName = obj.optString("advertisedName"),
                    modelName = obj.optString("modelName"),
                    lastSSID = obj.optString("lastSSID").takeIf { it.isNotEmpty() && obj.has("lastSSID") },
                    lastConnectedAt = obj.optLong("lastConnectedAt", 0L),
                    customName = obj.optString("customName").takeIf { it.isNotEmpty() && obj.has("customName") },
                    wifiSSID = obj.optString("wifiSSID").takeIf { it.isNotEmpty() && obj.has("wifiSSID") },
                    hotspotSSID = obj.optString("hotspotSSID").takeIf { it.isNotEmpty() && obj.has("hotspotSSID") },
                    lastSetup = obj.optString("lastSetup").takeIf { it.isNotEmpty() && obj.has("lastSetup") },
                ),
            )
        }
        return out
    }
}
