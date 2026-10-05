package com.opencapture.opencine.appkit.diagnostics

/**
 * The host app's identity and policy for diagnostics. Every name and destination belongs to the
 * app; this module owns none.
 */
public data class DiagnosticsHost(
    /** Product name in listings, copy and report subjects. */
    public val product: String,
    /** Events carry the release `<releasePackage>@<versionName>+<versionCode>`. */
    public val releasePackage: String,
    public val versionName: String,
    public val versionCode: Int,
    public val debug: Boolean,
    public val sourceRevision: String,
    /** The build's automatic-report destination (a DSN), if it has one. */
    public val reportingDsn: String?,
    /** Client name the manual report sends in its auth header. */
    public val reportingClient: String,
    public val supportEmail: String,
    /** Shared preferences file that keeps the operator's automatic-report choice. */
    public val preferencesName: String,
    /** The host's redaction policy for everything that leaves the phone. */
    public val redact: (String) -> String,
) {
    public fun release(versionName: String, versionCode: String): String =
        "$releasePackage@$versionName+$versionCode"

    public val currentRelease: String
        get() = release(versionName, versionCode.toString())

    public val environment: String
        get() = if (debug) "development" else "production"
}
