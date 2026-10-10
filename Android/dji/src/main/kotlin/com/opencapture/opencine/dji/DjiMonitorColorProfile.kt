package com.opencapture.opencine.dji

import com.opencapture.opencine.media.MonitorColorSourceProfile
import com.opencapture.opencine.media.MonitorTransfer
import com.opencapture.opencine.media.MonitorTransferInferenceRule

/** Actual DJI preview facts. Media never chooses these from an app/manufacturer name. */
object DjiMonitorColorProfile {
    val value = MonitorColorSourceProfile(clip = DjiScopeExposureCeiling.PROFILE,
        rec709LookCurves = mapOf(
            MonitorTransfer.DLOG2 to listOf(
                0.0000, 0.0048, 0.0294, 0.0657, 0.1016, 0.1390, 0.1854, 0.2390, 0.2987, 0.3631,
                0.4300, 0.4976, 0.5651, 0.6306, 0.6930, 0.7508, 0.8024, 0.8471, 0.8847, 0.9152,
                0.9392, 0.9571, 0.9702, 0.9796, 0.9865, 0.9916, 0.9953, 0.9977, 0.9991, 0.9998,
                1.0000, 1.0000, 1.0000,
                        ),
            MonitorTransfer.DLOG to listOf(
                0.0000, 0.0162, 0.0253, 0.0379, 0.0519, 0.0697, 0.0938, 0.1231, 0.1583, 0.1974,
                0.2451, 0.2989, 0.3568, 0.4155, 0.4741, 0.5322, 0.5896, 0.6463, 0.7019, 0.7561,
                0.8081, 0.8543, 0.8922, 0.9224, 0.9459, 0.9636, 0.9762, 0.9849, 0.9905, 0.9939,
                0.9962, 0.9988, 1.0000,
                        ),
            MonitorTransfer.DLOGM to listOf(
                0.0000, 0.0029, 0.0115, 0.0275, 0.0535, 0.0849, 0.1192, 0.1552, 0.1925, 0.2303,
                0.2692, 0.3090, 0.3488, 0.3883, 0.4239, 0.4563, 0.4874, 0.5193, 0.5538, 0.5908,
                0.6299, 0.6685, 0.7057, 0.7404, 0.7743, 0.8073, 0.8402, 0.8727, 0.9040, 0.9332,
                0.9604, 0.9832, 1.0000,
                        ),
        ), transferInference = listOf(
            MonitorTransferInferenceRule(MonitorTransfer.REC709, MonitorTransfer.DLOG2, 12..22, 180..252),
            MonitorTransferInferenceRule(MonitorTransfer.REC709, MonitorTransfer.DLOG, 20..30, 160..240),
        ))

    /** Empirical DJI preview signature; an already declared transfer always wins. */
    fun inferredTransfer(minByte: Int, maxByte: Int, fallback: MonitorTransfer): MonitorTransfer {
        return value.inferredTransfer(minByte, maxByte, fallback)
    }
}

/** Compatibility extension available only to consumers importing the DJI integration. */
fun MonitorTransfer.Companion.inferred(minByte: Int, maxByte: Int, fallback: MonitorTransfer): MonitorTransfer =
    DjiMonitorColorProfile.inferredTransfer(minByte, maxByte, fallback)
