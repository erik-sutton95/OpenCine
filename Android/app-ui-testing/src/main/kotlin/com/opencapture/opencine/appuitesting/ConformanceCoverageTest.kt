package com.opencapture.opencine.appuitesting

import kotlin.test.assertTrue
import org.junit.Test

/**
 * Fails when the app's androidTest source set leaves a conformance scenario out: a missing subclass
 * would otherwise just never run. The app's subclasses live in this class's package, named by
 * scenario ID (docs/conformance/SCENARIOS.md).
 */
@Conformance
public abstract class ConformanceCoverageTest(subject: ConformanceApp) : ConformanceTest(subject) {
    @Test
    public fun theAppRunsEveryScenario() {
        val bundle = javaClass.`package`?.name.orEmpty()
        for (scenario in SCENARIOS) {
            val id = scenario.simpleName
            val adopted = runCatching { Class.forName("$bundle.$id") }.getOrNull()
            assertTrue(
                adopted != null && adopted != scenario && scenario.isAssignableFrom(adopted),
                "Add `class $id : com.opencapture.opencine.appuitesting.$id(<app>)` to $bundle",
            )
        }
    }

    public companion object {
        public val SCENARIOS: List<Class<out ConformanceTest>> = listOf(
            GalleryRoundTrip::class.java, ShareRoundTrip::class.java, ConfirmationCancel::class.java,
            ChromeEditReturn::class.java, AccessibilityTraversal::class.java, ScreenMatrix::class.java,
        )
    }
}
