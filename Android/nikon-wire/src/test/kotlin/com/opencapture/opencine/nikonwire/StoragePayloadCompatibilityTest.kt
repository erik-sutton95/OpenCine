package com.opencapture.opencine.nikonwire

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import org.json.JSONObject

class StoragePayloadCompatibilityTest {
    private fun state(media: MonitorRelayWire.MediaStatus) = MonitorRelayWire.State(
        "STBY", "4K · 24p", "H.265", "59.6 GB · 47%", "24", 80, "Camera", "Lens", "", emptyList(), media, false,
    )

    @Test fun exactBytesAndUnknownDurationSurviveMonitorRelay() {
        val status = MonitorRelayWire.MediaStatus(60, 47, 0, estimatedMinutesRemaining = null, freeBytes = 59_600_000_000)
        val json = state(status).toJson()
        assertEquals(status, MonitorRelayWire.State.fromJson(json).mediaStatus)
        assertEquals(59_600_000_000, json.getJSONObject("mediaStatus").getLong("freeBytes"))
        assertNull(MonitorRelayWire.State.fromJson(json).mediaStatus?.estimatedMinutesRemaining)
    }

    @Test fun oldMonitorPayloadStillDecodesWithoutNewFields() {
        val json = state(MonitorRelayWire.MediaStatus(521, 47, 40)).toJson()
        json.getJSONObject("mediaStatus").remove("freeBytes")
        json.getJSONObject("mediaStatus").remove("estimatedMinutesRemaining")
        val decoded = MonitorRelayWire.State.fromJson(json).mediaStatus!!
        assertEquals(40, decoded.estimatedMinutesRemaining)
        assertNull(decoded.freeBytes)
    }
}
