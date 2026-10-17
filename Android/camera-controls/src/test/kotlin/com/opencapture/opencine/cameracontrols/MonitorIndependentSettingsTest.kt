package com.opencapture.opencine.cameracontrols

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.fail

/** SIMULATED host targets exercise the neutral row contract without a camera policy. */
class MonitorIndependentSettingsTest {
    private enum class Target { FIRST, SECOND }

    @Test fun unknownCurrentPreservesExactOrderedChoices() {
        val row = IndependentSettingRow("first", "First", listOf(" On ", "off", "ON"), null, Target.FIRST, null)
        assertEquals("first", row.id)
        assertEquals(listOf(" On ", "off", "ON"), row.options)
        assertNull(row.current)
        val outside = IndependentSettingRow<String, Target>("second", "Second", emptyList(),
            "unlisted observation", null, "Host refusal")
        assertEquals(emptyList(), outside.options)
        assertEquals("unlisted observation", outside.current)
    }

    @Test fun eachSelectionSendsOnlyItsExistingRequestAndExactOption() {
        val first = IndependentSettingRow("first", "First", listOf("off", " On "), "off", Target.FIRST, null)
        val second = IndependentSettingRow("second", "Second", listOf("off", "on"), null, Target.SECOND, null)
        val requests = mutableListOf<Target>()
        val options = mutableListOf<String>()
        var refusals = 0
        listOf(first to " On ", second to "on", first to "off").forEach { (row, option) ->
            row.select(option, true, { true }, { request, exact -> requests += request; options += exact },
                { _, _ -> refusals += 1 })
        }
        assertEquals(listOf(Target.FIRST, Target.SECOND, Target.FIRST), requests)
        assertEquals(listOf(" On ", "on", "off"), options)
        assertEquals(0, refusals)
        assertNull(second.current)
    }

    @Test fun missingRequestReportsOnlyTheHostReason() {
        var requests = 0
        val refusedIDs = mutableListOf<String>()
        val reasons = mutableListOf<String?>()
        listOf("Host refusal", null).forEach { reason ->
            val row = IndependentSettingRow<String, Target>("unavailable", "Unavailable", listOf("on"), null, null, reason)
            row.select("on", true, { true }, { _, _ -> requests += 1 },
                { id, detail -> refusedIDs += id; reasons += detail })
        }
        assertEquals(0, requests)
        assertEquals(listOf("unavailable", "unavailable"), refusedIDs)
        assertEquals(listOf("Host refusal", null), reasons)
    }

    @Test fun interactionAndSourceGuardsRefuseBeforeAnyCallback() {
        var callbacks = 0
        var sourceCurrent = true
        val row = IndependentSettingRow("first", "First", listOf("on"), null, Target.FIRST, null)
        val select = { enabled: Boolean ->
            row.select("on", enabled, { sourceCurrent }, { _, _ -> callbacks += 1 }, { _, _ -> callbacks += 1 })
        }
        select(false)
        sourceCurrent = false
        select(true)
        assertEquals(0, callbacks)
        sourceCurrent = true
        select(true)
        assertEquals(1, callbacks)
    }

    @Test fun unlistedOptionsAreNeverNormalizedOrSent() {
        val row = IndependentSettingRow("first", "First", listOf(" On "), null, Target.FIRST, null)
        var callbacks = 0
        listOf("On", "ON", "on", "", "off").forEach { option ->
            row.select(option, true, { true }, { _, _ -> callbacks += 1 }, { _, _ -> callbacks += 1 })
        }
        assertEquals(0, callbacks)
    }

    @Test fun reasonDoesNotInventAnAdmissionPolicyForAnExistingRequest() {
        val row = IndependentSettingRow("first", "First", listOf("on"), null, Target.FIRST, "Host detail")
        val requests = mutableListOf<Target>()
        row.select("on", true, { true }, { request, _ -> requests += request },
            { _, _ -> fail("The supplied request remains the host's decision") })
        assertEquals(listOf(Target.FIRST), requests)
    }
}
