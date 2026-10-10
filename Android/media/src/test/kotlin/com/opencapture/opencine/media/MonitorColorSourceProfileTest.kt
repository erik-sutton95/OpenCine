package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals

class MonitorColorSourceProfileTest {
    private val profile = MonitorColorSourceProfile(transferInference = listOf(
        MonitorTransferInferenceRule(MonitorTransfer.REC709, MonitorTransfer.DLOG2, 12..22, 180..252),
        MonitorTransferInferenceRule(MonitorTransfer.REC709, MonitorTransfer.DLOG, 20..30, 160..240),
    ))
    @Test fun absentSignatureNeverInfersADeclaredSource() {
        assertEquals(MonitorTransfer.REC709, MonitorColorSourceProfile().inferredTransfer(16, 247, MonitorTransfer.REC709))
        assertEquals(MonitorTransfer.ILOG, MonitorColorSourceProfile().inferredTransfer(24, 223, MonitorTransfer.ILOG))
    }
    @Test fun declaredTransferWinsOverPreviewSignature() {
        for (fallback in MonitorTransfer.entries.filter { it != MonitorTransfer.REC709 })
            assertEquals(fallback, profile.inferredTransfer(16, 247, fallback))
    }
    @Test fun orderedSignaturesPreserveOverlapAndInclusiveBounds() {
        assertEquals(MonitorTransfer.DLOG2, profile.inferredTransfer(20, 220, MonitorTransfer.REC709))
        assertEquals(MonitorTransfer.DLOG2, profile.inferredTransfer(12, 180, MonitorTransfer.REC709))
        assertEquals(MonitorTransfer.DLOG2, profile.inferredTransfer(22, 252, MonitorTransfer.REC709))
        assertEquals(MonitorTransfer.DLOG, profile.inferredTransfer(30, 160, MonitorTransfer.REC709))
        assertEquals(MonitorTransfer.REC709, profile.inferredTransfer(11, 247, MonitorTransfer.REC709))
        assertEquals(MonitorTransfer.REC709, profile.inferredTransfer(16, 253, MonitorTransfer.REC709))
    }
}
