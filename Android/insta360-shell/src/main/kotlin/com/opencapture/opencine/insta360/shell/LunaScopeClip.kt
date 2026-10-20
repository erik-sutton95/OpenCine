package com.opencapture.opencine.insta360.shell

import com.opencapture.opencine.media.MonitorTransfer
import com.opencapture.opencine.media.ScopeClipCalibration
import com.opencapture.opencine.media.ScopeClipProfile

/**
 * Luna preview clip calibration for I-Log, over the portable ISO-aware ceiling
 * (`ScopeExposureCeiling`). Twin of Swift `LunaScopeClip` in Insta360Protocol; the evidence and
 * the derivation are recorded there. Not hardware-measured: 248 at the native ISO 400 is the
 * lowest clip consistent with the owner's report, so the table warns early, never late.
 * ISO 100 205, 160 220, 200 227, 400 and above 248. An unreported Auto ISO assumes ISO 100.
 */
public object LunaScopeClip {
    /** Insta360: I-Log has one native ISO, 400. */
    public const val NATIVE_ISO: Int = 400
    /** Lowest ISO the Luna offers (100, 160, 200, 400 ... 6400). */
    public const val LOWEST_ISO: Int = 100
    /** Derived live-tap I-Log clip at ISO 400 (needs a hardware measurement). */
    public const val ILOG_CLIP_BYTE_AT_NATIVE: Int = 248
    /** Highest tap maximum at or above ISO 400 accepted as the real clip. */
    public const val ILOG_CLIP_BYTE_AT_NATIVE_HIGH: Int = 254

    public val PROFILE: ScopeClipProfile = ScopeClipProfile(mapOf(
        MonitorTransfer.ILOG to ScopeClipCalibration(NATIVE_ISO, ILOG_CLIP_BYTE_AT_NATIVE,
            ILOG_CLIP_BYTE_AT_NATIVE_HIGH, refinementAtOrAboveReference = true),
    ), defaultIso = LOWEST_ISO, unreportedIso = LOWEST_ISO)
}
