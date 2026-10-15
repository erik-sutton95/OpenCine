package com.opencapture.opencine.appkit.diagnostics

import android.os.Build

/**
 * The phone as every diagnostic names it: one hardware class, OS name and version for incident
 * sessions, problem reports and the diagnostics export, computed here once instead of in each app
 * (A6-13). Swift twin: `OpenCineAppKit/DiagnosticsDevice.swift`.
 */
public data class DiagnosticsDevice(
    /** `Build.MODEL`, for example `Pixel 9 Pro`. */
    public val hardwareClass: String,
    public val osName: String,
    /** `Build.VERSION.RELEASE`, for example `16`. */
    public val osVersion: String,
) {
    public companion object {
        public fun current(): DiagnosticsDevice =
            of(model = Build.MODEL, release = Build.VERSION.RELEASE)

        /** Absent or blank build values read `unknown`. */
        public fun of(model: String?, release: String?): DiagnosticsDevice =
            DiagnosticsDevice(
                hardwareClass = model?.trim()?.ifEmpty { null } ?: "unknown",
                osName = "Android",
                osVersion = release?.trim()?.ifEmpty { null } ?: "unknown",
            )
    }
}
