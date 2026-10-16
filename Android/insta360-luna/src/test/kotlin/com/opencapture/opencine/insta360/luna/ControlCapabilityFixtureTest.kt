package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.MonitorLayoutCapabilities
import com.opencapture.opencine.vocabulary.ControlCapabilityVectors
import com.opencapture.opencine.vocabulary.MonitorLayoutCapabilities
import java.io.File
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel

/**
 * The Kotlin twin renders the same control model as the Swift Luna integration
 * (`Fixtures/control-capabilities-luna.tsv`, written by Swift `ControlCapabilityFixtureTests`).
 */
class ControlCapabilityFixtureTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @AfterTest fun tearDown() = scope.cancel()

    @Test
    fun fixtureMatchesTheSwiftIntegration() {
        val controls = FakeLuna(scope).connectedSession().controlCapabilities()
        val rendered = ControlCapabilityVectors.document("luna", listOf("Luna Ultra" to controls))
        val fixture = File(System.getProperty("opencine.fixtures"), "control-capabilities-luna.tsv")
        assertEquals(fixture.readText(), rendered)
    }

    @Test
    fun layoutIsAViewOfTheModel() {
        val session = FakeLuna(scope).connectedSession()
        val base = MonitorLayoutCapabilities(audio = true, clipDelete = true, clipStar = true, requiresInternetHop = true)
        assertEquals(session.layout(base), MonitorLayoutCapabilities(session.controlCapabilities(), base))
    }
}
