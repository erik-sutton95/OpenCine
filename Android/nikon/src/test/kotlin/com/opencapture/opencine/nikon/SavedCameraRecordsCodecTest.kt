package com.opencapture.opencine.nikon

import org.json.JSONArray
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The saved setups as OpenZCine's Android app writes them, through the one codec of its records
 * ([NikonSavedRecordsV0.encode] and [NikonSavedRecordsV0.decode]). The golden fixture is what the
 * app's own store wrote before the codec moved here: every key and value must read back unchanged.
 * Regenerate with `OPENCINE_WRITE_FIXTURES=<path to nikon-records-v0-android.json> ./gradlew
 * :nikon:testDebugUnitTest --tests '*SavedCameraRecordsCodecTest*'`.
 */
class SavedCameraRecordsCodecTest {
    private val at = 1_759_307_200_250L
    private val golden = File(System.getProperty("opencine.fixtures"), "saved-cameras/nikon-records-v0-android.json")

    /**
     * Body A paired on its access point, then given a Studio Wi-Fi setup and a USB-C setup, renamed
     * on every path; body B on the phone's hotspot; body C on its access point under a pending key;
     * and a camera that never reported a name.
     */
    private fun appRecords(): List<SavedCameraRecord> {
        var records = emptyList<SavedCameraRecord>()
        records = SavedCameraRecords.upserting(
            "192.168.1.1", "ZR_3001234", SavedCameraTransport.CAMERA_ACCESS_POINT, at, "NIKON_ZR_3001234", records,
        )
        records = SavedCameraRecords.upserting(
            "192.168.50.23", "ZR_3001234", SavedCameraTransport.INFRASTRUCTURE, at + 200_000, null, records,
            networkName = "Studio",
        )
        records = SavedCameraRecords.upserting(
            "usb:3f9a2c", "ZR_3001234", SavedCameraTransport.USB_C, at + 100_000, null, records,
        )
        records = records.map { record ->
            record.copy(
                customName = "A-cam",
                setupName = "Studio".takeIf { record.host == "192.168.50.23" },
            )
        }
        records = SavedCameraRecords.updatingStreamSettings(
            "192.168.1.1", SavedCameraTransport.CAMERA_ACCESS_POINT, "FAST", "LATENCY", records,
        )
        records = SavedCameraRecords.upserting(
            "192.168.43.20", "ZR_4005678", SavedCameraTransport.PHONE_HOTSPOT, at + 300_000, null, records,
        )
        records = SavedCameraRecords.upserting(
            "", "Z_8_5009999", SavedCameraTransport.CAMERA_ACCESS_POINT, at - 100_000, "NIKON_Z8_5009999", records,
        ).let { it + SavedCameraRecords.pinnedToAccessPoint(
            SavedCameraRecord("x", "Z_8_5009999", SavedCameraTransport.CAMERA_ACCESS_POINT, at - 100_000, "NIKON_Z8_5009999"),
        ) }
        return SavedCameraRecords.upserting("10.0.0.5", "", SavedCameraTransport.INFRASTRUCTURE, null, null, records)
    }

    @Test
    fun `the codec writes what the golden fixture holds and reads it back`() {
        val written = NikonSavedRecordsV0.encode(appRecords())
        System.getenv("OPENCINE_WRITE_FIXTURES")?.takeIf { it.endsWith(".json") }?.let { File(it).writeText(written) }
        assertEquals(fields(golden.readText()), fields(written))
        assertEquals(SavedCameraRecords.canonicalized(appRecords()), NikonSavedRecordsV0.decode(golden.readText()))
    }

    /** Each record's keys and values, whatever order the JSON library writes them in. */
    private fun fields(json: String): List<Map<String, String>> {
        val array = JSONArray(json)
        return (0 until array.length()).map { index ->
            val record = array.getJSONObject(index)
            record.keys().asSequence().associateWith { record.get(it).toString() }
        }
    }

    @Test
    fun `an undecodable element or a record without a host is skipped, not fatal`() {
        val data = """[{"host":" "},7,{"host":"192.168.1.9","camera-name":"ZR_1","transport":"later-kind","stream-preset":" "}]"""
        val record = NikonSavedRecordsV0.decode(data).single()
        assertEquals(SavedCameraTransport.PHONE_HOTSPOT, record.transport)
        assertEquals(null, record.streamPreset)
        assertEquals(emptyList(), NikonSavedRecordsV0.decode("not json"))
        assertEquals(emptyList(), NikonSavedRecordsV0.decode(null))
    }
}
