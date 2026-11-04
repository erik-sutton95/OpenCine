package com.opencapture.opencine.insta360.luna

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Station mode wire shapes (Swift `LunaStationTests`, same vectors): the official app's encoders,
 * with the plaintext lengths of the 2026-10-01 router-join take (147: 8 bytes, 112 and 215: 29
 * bytes for an 11-byte name and a 12-byte password).
 */
class LunaStationWireTest {
    private fun hex(value: String) = LunaWire.hex(value.filterNot { it.isWhitespace() })
    private fun text(value: String) = value.toByteArray()

    @Test fun wiFiModeRequestsMatchTheOfficialEncoder() {
        val station = LunaStationWire.wifiMode(LunaStationWire.Mode.STATION, "US")
        assertContentEquals(hex("08011001 1a025553"), station)
        assertEquals(8, station.size, "the captured station switch is 8 plaintext bytes")
        assertContentEquals(hex("0801"), LunaStationWire.wifiMode(LunaStationWire.Mode.ACCESS_POINT, null))
        assertContentEquals(hex("08011001"), LunaStationWire.wifiMode(LunaStationWire.Mode.STATION, null))
        assertContentEquals(hex("08011001"), LunaStationWire.wifiMode(LunaStationWire.Mode.STATION, "united"))
        assertEquals(147, LunaStationWire.SET_WIFI_MODE)
    }

    @Test fun stationJoinAndRememberCarryTheNetworkNameAndPassword() {
        val join = LunaStationWire.join("Studio", "synthetic1")
        assertContentEquals(hex("0a14 0a06") + text("Studio") + hex("1a0a") + text("synthetic1"), join)
        assertContentEquals(join, LunaStationWire.remember("Studio", "synthetic1"))
        assertEquals(112, LunaStationWire.SET_WIFI_CONNECTION_INFO)
        assertEquals(215, LunaStationWire.SET_AVAILABLE_WIFI)
        assertEquals(29, LunaStationWire.join("n".repeat(11), "p".repeat(12)).size, "the captured join is 29 plaintext bytes")
        assertContentEquals(hex("0a06 0a04") + text("Open"), LunaStationWire.join("Open", ""))
    }

    @Test fun stationJoinRejectsNetworksTheCameraCannotJoin() {
        assertFailsWith<IllegalArgumentException> { LunaStationWire.join("", "synthetic1") }
        assertFailsWith<IllegalArgumentException> { LunaStationWire.join("a".repeat(33), "synthetic1") }
        assertFailsWith<IllegalArgumentException> { LunaStationWire.join("Studio", "short") }
        assertFailsWith<IllegalArgumentException> { LunaStationWire.join("Studio", "p".repeat(64)) }
        assertFailsWith<IllegalArgumentException> { LunaStationWire.join("St\u0000udio", "synthetic1") }
        assertTrue(LunaStationWire.accepts("Studio", "synthetic1"))
        assertTrue(LunaStationWire.accepts("Open", ""))
        assertFalse(LunaStationWire.accepts("Studio", "short"))
    }

    @Test fun phoneInfoNamesThisPhone() {
        assertContentEquals(
            hex("0801 1205") + text("Apple") + hex("1a06") + text("iPhone") + hex("2204") + text("27.0"),
            LunaStationWire.phoneInfo(LunaStationWire.Platform.IOS, "Apple", "iPhone", "27.0"),
        )
        assertContentEquals(hex("0802"), LunaStationWire.phoneInfo(LunaStationWire.Platform.ANDROID, "", "", ""))
        assertEquals(220, LunaStationWire.PHONE_INFO)
    }

    @Test fun joinResultNotificationReadsSuccessAndFailureWithoutLeakingThePassword() {
        val info = hex("0a06") + text("Studio") + hex("1200 1a0a") + text("synthetic1") + hex("2800 3000")
        val joined = LunaStationWire.joinResult(hex("0800 12") + byteArrayOf(info.size.toByte()) + info)
        assertEquals(LunaStationWire.JoinResult.Outcome.Joined, joined.outcome)
        assertEquals("Studio", joined.ssid)
        assertNull(joined.address)
        assertFalse(joined.toString().contains("synthetic1"))
        assertEquals(LunaStationWire.JoinResult.Outcome.Joined, LunaStationWire.joinResult(ByteArray(0)).outcome)
        assertEquals(LunaStationWire.JoinResult.Outcome.WrongPassword, LunaStationWire.joinResult(hex("0803")).outcome)
        assertEquals(LunaStationWire.JoinResult.Outcome.NetworkNotFound, LunaStationWire.joinResult(hex("0806")).outcome)
        assertEquals(LunaStationWire.JoinResult.Outcome.Failed(1), LunaStationWire.joinResult(hex("0801")).outcome)
        val addressed = hex("0a06") + text("Studio") + hex("2208") + text("10.0.0.9")
        assertEquals("10.0.0.9", LunaStationWire.joinResult(hex("12") + byteArrayOf(addressed.size.toByte()) + addressed).address)
        assertEquals(8232, LunaStationWire.JOIN_RESULT)
    }

    @Test fun countryCodeComesFromTheCredentialReadsChannelList() {
        val wifi = LunaWire.blob(36, LunaWire.blob(1, text("LUNA-TEST")) + LunaWire.blob(2, text("synthetic-password")))
        val channels = LunaWire.blob(37, LunaWire.blob(1, text("DK")) + LunaWire.blob(2, hex("01060b")))
        assertEquals("DK", LunaStationWire.countryCode(hex("0a0324252b") + LunaWire.blob(2, wifi + channels)))
        assertNull(LunaStationWire.countryCode(hex("0a0324252b") + LunaWire.blob(2, wifi)))
    }

    /** Swift `LunaStationPathTests`: where a Wi-Fi or hotspot setup looks for the camera. */
    @Test fun aPersonalHotspotSearchesItsWholeSubnet() {
        val hosts = LunaStationWire.candidates("172.20.10.1", 28)
        assertEquals(13, hosts.size, "a /28 without the phone, the network and the broadcast address")
        assertTrue(hosts.first() == "172.20.10.2" && "172.20.10.1" !in hosts)
        assertTrue("172.20.10.0" !in hosts && "172.20.10.15" !in hosts)
    }

    @Test fun aLargeNetworkSearchesThePhonesOwnBlockNearestFirst() {
        val hosts = LunaStationWire.candidates("10.4.7.200", 16)
        assertEquals(253, hosts.size)
        assertEquals(listOf("10.4.7.199", "10.4.7.201"), hosts.take(2).sorted())
        assertTrue(hosts.all { it.startsWith("10.4.7.") })
    }
}
