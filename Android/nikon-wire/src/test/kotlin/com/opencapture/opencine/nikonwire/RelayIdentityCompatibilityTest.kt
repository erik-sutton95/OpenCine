package com.opencapture.opencine.nikonwire

import org.json.JSONObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class RelayIdentityCompatibilityTest {
    @Test fun deployedOutgoingIdentitySpellingIsUnchangedAndBothPeerSpellingsAreRead() {
        val hello = MonitorRelayWire.Hello(2, "Phone", null, watcherId = "install")
        val encoded = hello.toJson()
        assertEquals("install", encoded.getString("watcherId"))
        assertFalse(encoded.has("watcherID"))
        assertEquals("install", MonitorRelayWire.Hello.fromJson(JSONObject("""{"version":2,"hostName":"Phone","watcherID":"install"}""")).watcherId)
        assertEquals("android", MonitorRelayWire.Hello.fromJson(JSONObject("""{"version":2,"hostName":"Phone","watcherID":"apple","watcherId":"android"}""")).watcherId)
    }
    @Test fun presenceRemainsPassiveTCPWithExactTXTAndCodecFacts() {
        assertEquals(15741, MonitorRelayWire.PRESENCE_TCP_PORT)
        assertEquals("_openzcine-mon._tcp", MonitorRelayWire.SERVICE_TYPE)
        assertEquals(0, MonitorRelayWire.FrameCodec.JPEG)
        assertEquals(1, MonitorRelayWire.FrameCodec.HEVC)
        val line = MonitorRelayWire.relayPresenceLine("Phone", false, "192.168.1.8", null)
        val json = JSONObject(line)
        assertEquals(0, json.getInt("w"))
        assertEquals("192.168.1.8", json.getString("ch"))
        assertFalse(json.has("p"))
        assertEquals('\n', line.last())
    }
}
