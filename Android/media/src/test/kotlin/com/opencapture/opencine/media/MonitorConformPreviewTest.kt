package com.opencapture.opencine.media

import kotlin.test.*

/** Existing donor preview goldens; export and native file probing are separate. */
class MonitorConformPreviewTest {
    @Test fun speedLabelAndDurationFollowTheTargetRate() {
        assertEquals(0.4, MonitorConformPreview.speed(60.0, 24.0))
        assertEquals("60 → 24 fps · 40%", MonitorConformPreview.label(60.0, 24.0))
        assertEquals(0.2, MonitorConformPreview.speed(120.0, 24.0))
        assertEquals(MonitorConformPreview.targetRates, MonitorConformPreview.availability(MonitorConformPreview.Source(120.0)).targets)
        assertEquals(15.0, MonitorConformPreview.conformedDuration(6.0, MonitorConformPreview.speed(60.0, 24.0)))
    }
    @Test fun onlySlowerTargets() {
        assertEquals(listOf(23.976, 24.0, 25.0), MonitorConformPreview.availability(MonitorConformPreview.Source(30.0)).targets)
        val twentyFour = MonitorConformPreview.availability(MonitorConformPreview.Source(24.0))
        assertEquals(MonitorConformPreview.Availability.NotHighFrameRate, twentyFour)
        assertFalse(twentyFour.isAvailable)
    }
    @Test fun refusalsExplainWhy() {
        assertEquals(MonitorConformPreview.Availability.UnknownRate, MonitorConformPreview.availability(MonitorConformPreview.Source()))
        assertEquals(MonitorConformPreview.Availability.VariableRate, MonitorConformPreview.availability(MonitorConformPreview.Source(120.0, isVariableFrameRate = true)))
        assertEquals(MonitorConformPreview.Availability.AlreadyConformed, MonitorConformPreview.availability(MonitorConformPreview.Source(120.0, isAlreadyConformed = true)))
        for (source in listOf(MonitorConformPreview.Source(), MonitorConformPreview.Source(120.0, isVariableFrameRate = true),
            MonitorConformPreview.Source(120.0, isAlreadyConformed = true), MonitorConformPreview.Source(24.0))) {
            assertNotNull(MonitorConformPreview.availability(source).unavailableReason)
        }
    }
    @Test fun probeUsesMinDurationWhenNominalIsZero() {
        val source = MonitorConformPreview.probe(nominalFrameRate = 0.0, minFrameDurationSeconds = 1.0 / 50.0)
        assertEquals(50.0, source.captureRate); assertFalse(source.isVariableFrameRate)
    }
    @Test fun timescaleArtifactIsNotVariableRate() {
        val source = MonitorConformPreview.probe(nominalFrameRate = 50.0, minFrameDurationSeconds = 1.0 / 1000.0)
        assertEquals(50.0, source.captureRate); assertFalse(source.isVariableFrameRate)
    }

    @Test fun sourceFrameIndexPreservesTheDonorTimeline() {
        val speed = MonitorConformPreview.speed(60.0, 24.0)
        assertEquals(360, MonitorConformPreview.sourceFrameIndex(15.0, 60.0, speed))
        assertEquals(180, MonitorConformPreview.sourceFrameIndex(7.5, 60.0, speed))
        assertEquals(0, MonitorConformPreview.sourceFrameIndex(0.0, 60.0, speed))
    }

    @Test fun refusalOrderPreservesTheDonorContract() {
        assertEquals(MonitorConformPreview.Availability.UnknownRate,
            MonitorConformPreview.availability(MonitorConformPreview.Source(0.0, true, true)))
        assertEquals(MonitorConformPreview.Availability.UnknownRate,
            MonitorConformPreview.availability(MonitorConformPreview.Source(Double.NaN)))
        assertEquals(MonitorConformPreview.Availability.VariableRate,
            MonitorConformPreview.availability(MonitorConformPreview.Source(120.0, true, true)))
    }

    @Test fun labelsAndInvalidDurationPreserveTheDonorGoldens() {
        assertEquals("23.98", MonitorConformPreview.rateLabel(23.976))
        assertEquals("29.97", MonitorConformPreview.rateLabel(29.97))
        assertEquals("\u2014", MonitorConformPreview.rateLabel(0.0))
        assertEquals("59.94 → 23.98 fps · 40%", MonitorConformPreview.label(59.94, 23.976))
        assertEquals("120 → 25 fps · 20.8%", MonitorConformPreview.label(120.0, 25.0))
        assertEquals("29.97 fps · 59.9%", MonitorConformPreview.targetLabel(50.0, 29.97))
        assertEquals("Conform 50 fps to", MonitorConformPreview.menuHeader(50.0))
        assertEquals(0.0, MonitorConformPreview.conformedDuration(6.0, 0.0))
        assertEquals(0.0, MonitorConformPreview.conformedDuration(Double.POSITIVE_INFINITY, 0.4))
    }
}
