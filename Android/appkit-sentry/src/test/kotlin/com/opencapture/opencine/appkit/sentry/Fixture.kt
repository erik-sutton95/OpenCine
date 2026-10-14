package com.opencapture.opencine.appkit.sentry

import com.opencapture.opencine.appkit.diagnostics.DiagnosticsHost
import com.opencapture.opencine.appkit.diagnostics.FeedIncidentOrigin
import com.opencapture.opencine.appkit.diagnostics.ManualProblemReport
import com.opencapture.opencine.appkit.diagnostics.ReliabilityReporting
import com.opencapture.opencine.appkit.diagnostics.ReliabilityReportingConsent
import com.opencapture.opencine.appkit.diagnostics.ReliabilityReportingDSN
import com.opencapture.opencine.appkit.diagnostics.ReliabilityReportingGate
import com.opencapture.opencine.appkit.diagnostics.ReliabilityReportingHostPolicy
import com.opencapture.opencine.media.PrivacyRedactor

/** A host of the adapter, as an app's diagnostics holder builds it (the moved tests ran on Pocket's). */
internal object Fixture {
    val host =
        DiagnosticsHost(
            product = "Host",
            releasePackage = "com.opencapture.host",
            versionName = "0.2.0",
            versionCode = 200,
            environment = "development",
            sourceRevision = "test",
            reportingDsn = null,
            reportingClient = "host-android",
            supportEmail = "support@host.invalid",
            preferencesName = "host.operator",
            redact = { PrivacyRedactor.redact(it) },
        )
    val dsn = ReliabilityReportingDSN()
    val consent = ReliabilityReportingConsent(dsn)
    val gate = ReliabilityReportingGate(consent, ReliabilityReportingHostPolicy(), cameraIPv4Prefix = "192.168.2.")
    val origin = FeedIncidentOrigin({ "android-test" }, host.redact)
    val reporting =
        ReliabilityReporting(host, consent, dsn, gate, origin, ::SentryReliabilitySink) {
            manualReport.noteCameraPathClear()
        }
    val manualReport = ManualProblemReport(host, dsn, gate, OkHttpManualReportUpload)
}
