package com.opencapture.opencine.relay

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

public class RelayNearbyPolicyTest {
    @Test public fun authoritativePresenceSweepRetainsShieldButAddsOnlyJoinableEndpoint(): Unit {
        val shield = RelayBroadcast("Held in-use", "h1", 5010, "camera", false)
        val live = RelayBroadcast("Live", "h2", 5020, null)
        val sightings = mapOf(
            "h1" to RelayPresence("Held", false, "camera", null),
            "h2" to RelayPresence("Live", true, null, 5021),
            "h3" to RelayPresence("Only direct", true, "other-camera", 5030),
            "h4" to RelayPresence("Self", true, null, 5040),
            "h5" to RelayPresence("Portless", true, null, null),
        )
        assertEquals(listOf(shield, live, RelayBroadcast("Only direct", "h3", 5030, "other-camera")),
            RelayNearbyPolicy.merge(listOf(shield, live), sightings, "Self"))
        assertEquals(listOf(shield, live), RelayNearbyPolicy.merge(listOf(shield, live), emptyMap(), "Self"))
        assertEquals(listOf(shield, RelayBroadcast("Live", "h2", 5021, null)),
            RelayNearbyPolicy.merge(listOf(shield, live), sightings.filterKeys { it == "h2" }, "Self", setOf("Live")))
    }
    @Test public fun filteringIsContinuousTenSecondsAndNeverCountsCameraInUseShield(): Unit {
        val presence = mapOf("h" to RelayPresence("Live", true, null, 5020))
        var hidden = RelayNearbyPolicy.hiddenSince(presence, emptySet(), "Self", emptyMap(), 1_000)
        hidden = RelayNearbyPolicy.hiddenSince(presence, emptySet(), "Self", hidden, 10_999)
        assertFalse(RelayNearbyPolicy.provesFiltering(hidden, 10_999))
        assertTrue(RelayNearbyPolicy.provesFiltering(hidden, 11_000))
        hidden = RelayNearbyPolicy.hiddenSince(presence, setOf("Live"), "Self", hidden, 11_001)
        assertEquals(emptyMap(), hidden)
        hidden = RelayNearbyPolicy.hiddenSince(presence, emptySet(), "Self", hidden, 12_000)
        assertEquals(mapOf("Live" to 12_000L), hidden)
        assertFalse(RelayNearbyPolicy.provesFiltering(hidden, 12_000))
        assertEquals(emptyMap(), RelayNearbyPolicy.hiddenSince(emptyMap(), emptySet(), "Self", hidden, 30_000))
        assertEquals(emptyMap(), RelayNearbyPolicy.hiddenSince(
            mapOf("h" to RelayPresence("Held", false, "camera", null)), emptySet(), "Self", emptyMap(), 0))
    }
}
