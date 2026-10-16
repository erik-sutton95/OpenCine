package com.opencapture.opencine.nikonwire

import org.json.JSONObject
import kotlin.test.Test
import com.opencapture.opencine.core.BatteryReading
import kotlin.test.assertNull
import kotlin.test.assertFailsWith
import kotlin.test.assertEquals

/** SIMULATED deployed payload; a reading and exhaustion are separate reported facts. */
class BatteryRelayPrecisionTest {
    @Test fun aWatchRoundTripRetainsDeclaredStepsAndExhaustion() {
        val original = """{"recordState":"standby","timecode":{"on":false,"hour":0,"minute":0,"second":0,"frame":0},"media":"Unavailable","cameraBatteryPercent":80,"cameraName":"SIMULATED","isRecording":false,"connection":"connected","feedLive":true,"liveFPS":"Unavailable","batteryReading":{"kind":"steps","filled":1,"of":5},"batteryExhausted":true}"""
        val state = WatchRelayEnvelope.decode(byteArrayOf(WatchRelayKind.STATE.tag.toByte()) + original.toByteArray())
        val encoded = WatchRelayEnvelope.encode(state)
        val output = JSONObject(String(encoded.copyOfRange(1, encoded.size)))
        val input = JSONObject(original)
        assertEquals(input.getJSONObject("batteryReading").toMap(), output.optJSONObject("batteryReading")?.toMap())
        assertEquals(true, output.opt("batteryExhausted"))
    }

    @Test fun oldMissingFieldsAndExplicitNullHaveDifferentMeanings() {
        val old = """{"recordState":"standby","timecode":{"on":false,"hour":0,"minute":0,"second":0,"frame":0},"media":"Unavailable","cameraBatteryPercent":20,"cameraName":"SIMULATED","isRecording":false,"connection":"connected","feedLive":true,"liveFPS":"Unavailable"}"""
        fun decode(body: String) = WatchRelayEnvelope.decode(byteArrayOf(WatchRelayKind.STATE.tag.toByte()) + body.toByteArray()) as WatchRelayState
        val legacy = decode(old)
        assertEquals(BatteryReading.Steps(1, 5), legacy.batteryReading)
        assertEquals(false, legacy.batteryExhausted)
        val explicit = old.dropLast(1) + """, "batteryReading":null,"batteryExhausted":null}"""
        val unknown = decode(explicit)
        assertNull(unknown.batteryReading)
        assertNull(unknown.batteryExhausted)
        val wire = WatchRelayEnvelope.encode(unknown)
        val body = JSONObject(String(wire.copyOfRange(1, wire.size)))
        assertEquals(JSONObject.NULL, body.get("batteryReading"))
        assertEquals(JSONObject.NULL, body.get("batteryExhausted"))
        val zero = decode(explicit.replace("null,\"batteryExhausted\":null", "{\"kind\":\"steps\",\"filled\":0,\"of\":5},\"batteryExhausted\":false"))
        assertEquals(BatteryReading.Steps(0, 5), zero.batteryReading)
        assertEquals(false, zero.batteryExhausted)
    }

    @Test fun invalidReadingsAreRejectedRatherThanPresentedAsKnownZero() {
        val base = """{"recordState":"standby","timecode":{"on":false,"hour":0,"minute":0,"second":0,"frame":0},"media":"Unavailable","cameraBatteryPercent":80,"cameraName":"SIMULATED","isRecording":false,"connection":"connected","feedLive":true,"liveFPS":"Unavailable","batteryReading":REPLACE}"""
        for (reading in listOf("""{"kind":"fraction","value":1.1}""", """{"kind":"steps","filled":-1,"of":5}""",
            """{"kind":"steps","filled":1,"of":0}""", """{"kind":"unknown"}""")) {
            assertFailsWith<WatchRelayWireException.MalformedPayload> {
                WatchRelayEnvelope.decode(byteArrayOf(WatchRelayKind.STATE.tag.toByte()) + base.replace("REPLACE", reading).toByteArray())
            }
        }
    }

    private fun JSONObject.toMap(): Map<String, Any?> = keys().asSequence().associateWith { opt(it) }
}
