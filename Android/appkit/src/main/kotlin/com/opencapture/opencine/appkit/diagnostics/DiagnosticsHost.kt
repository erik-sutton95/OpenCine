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
    /** Legacy source contract. New hosts declare their reporting environment explicitly. */
    @Deprecated("Use the constructor with an explicit reporting environment.")
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
    private val declaredEnvironment: String? = null,
) {
    /** The reporting plugin's channel is authoritative for migrated hosts. */
    public constructor(
        product: String,
        releasePackage: String,
        versionName: String,
        versionCode: Int,
        environment: String,
        sourceRevision: String,
        reportingDsn: String?,
        reportingClient: String,
        supportEmail: String,
        preferencesName: String,
        redact: (String) -> String,
    ) : this(
        product, releasePackage, versionName, versionCode, environment == "development",
        sourceRevision, reportingDsn, reportingClient, supportEmail, preferencesName, redact,
        environment,
    )

    /** Legacy hosts retain their original mapping until they supply an explicit channel. */
    public val environment: String
        get() = declaredEnvironment ?: if (debug) "development" else "production"

    public fun release(versionName: String, versionCode: String): String =
        "$releasePackage@$versionName+$versionCode"

    public val currentRelease: String
        get() = release(versionName, versionCode.toString())
}
