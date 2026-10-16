package com.opencapture.opencine.nikon

import com.opencapture.opencine.media.Log3G10
import com.opencapture.opencine.media.MonitorLogDisplayTransform
import com.opencapture.opencine.media.MonitorTransfer
import com.opencapture.opencine.media.NLog

/** Nikon's generated look declarations; camera wire inference and clip calibration stay separate. */
// Original matrices: Nikon N-Log specification1.0.0 (N-Gamut is BT.2020), RED
// REDWideGamutRGB and Log3G10 white paper Rev B. Shared tone mapping uses inverse BT.1886.
object NikonMonitorColorProfile {
    /** REDWideGamutRGB/Log3G10 to the existing scene-anchored Rec.709 display look. */
    val log3G10Rec709 = MonitorLogDisplayTransform({ Log3G10.decode(it) }, floatArrayOf(
        1.981880f, -0.900388f, -0.081540f,
        -0.178143f, 1.500467f, -0.322325f,
        -0.101811f, -0.535343f, 1.637304f,
    ))

    /** N-Gamut (BT.2020)/N-Log to the existing scene-anchored Rec.709 display look. */
    val nLogRec709 = MonitorLogDisplayTransform({ NLog.decode(it) }, floatArrayOf(
        1.660491f, -0.587641f, -0.072850f,
        -0.124550f, 1.132900f, -0.008349f,
        -0.018151f, -0.100579f, 1.118730f,
    ))

    /** Only the two declared log looks support a read-through-display measurement. */
    val rec709LookCurves: Map<MonitorTransfer, List<Double>> = mapOf(
        MonitorTransfer.LOG3G10 to log3G10Rec709.neutralLumaCurve(),
        MonitorTransfer.NLOG to nLogRec709.neutralLumaCurve(),
    )
}
