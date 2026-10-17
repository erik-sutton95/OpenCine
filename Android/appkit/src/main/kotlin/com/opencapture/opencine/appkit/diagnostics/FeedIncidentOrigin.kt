package com.opencapture.opencine.appkit.diagnostics

import com.opencapture.monitorui.ReviewLaunch
import com.opencapture.opencine.media.FeedIncidentBuildIdentity
import com.opencapture.opencine.media.FeedIncidentTestSource

/**
 * Current-run origin only. Cached incidents keep the values persisted with them. [buildIdentity]
 * reads the host build's identity (it may throw when the build has none); [redact] is the host's
 * redaction policy.
 */
public class FeedIncidentOrigin(
    private val buildIdentity: () -> String?,
    private val redact: (String) -> String,
) {
    @Volatile public var overrideTestSourceForTests: FeedIncidentTestSource? = null
    @Volatile public var overrideBuildIdentityForTests: String? = null
    @Volatile public var injectionActivatedForTests: Boolean = false

    public fun resetForTests() {
        overrideTestSourceForTests = null
        overrideBuildIdentityForTests = null
        injectionActivatedForTests = false
    }

    public fun currentTestSource(): FeedIncidentTestSource {
        overrideTestSourceForTests?.let { return it }
        val env = System.getenv()
        val verification =
            env["OPV_RELIABILITY_VERIFY"] in
                setOf("incident", "gatedIncident", "crash", "hang", "resume")
        return FeedIncidentTestSource.derive(
            verification = verification,
            injectionActivated = injectionActivatedForTests,
            automation = isAutomationLaunch(env) || isAutomatedHarness(),
        )
    }

    public fun isAutomationLaunch(environment: Map<String, String>): Boolean {
        if (environment["OPV_FEED_STRESS"] == "1") return true
        if (environment["OPV_PHYSICAL_UI_REVIEW"] == "1") return true
        // Any staged screen, the shared review contract's or an app-only one.
        if (!environment[ReviewLaunch.Key.SCREEN].isNullOrEmpty()) return true
        return false
    }

    public fun currentBuildIdentity(): String {
        overrideBuildIdentityForTests?.let { return FeedIncidentBuildIdentity.parse(it, redact) }
        return FeedIncidentBuildIdentity.parse(runCatching { buildIdentity() }.getOrNull(), redact)
    }

    private fun isAutomatedHarness(): Boolean {
        return try {
            Class.forName("org.junit.Test")
            true
        } catch (_: ClassNotFoundException) {
            try {
                Class.forName("androidx.test.platform.app.InstrumentationRegistry")
                true
            } catch (_: ClassNotFoundException) {
                false
            }
        }
    }
}
