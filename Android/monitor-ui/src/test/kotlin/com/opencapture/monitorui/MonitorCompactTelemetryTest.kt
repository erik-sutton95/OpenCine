package com.opencapture.monitorui

import androidx.compose.ui.unit.Density
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MonitorCompactTelemetryTest {
    @Test fun storageStillClearsPowerWhenTheLinkIsUnknown() {
        val fit = MonitorCompactTelemetryBudget(MonitorLayoutPolicy.fieldMonitor(320f, 956f),
            0f, 0f, 86f, 289f, 0f, 48f, 2f)
        assertTrue(fit.wrapsPower)
        assertEquals(86f, fit.storageWidth)
    }

    @Test fun nativeContentThatExceedsTheSingleRowMovesPowerToASeparateLine() {
        val fit = MonitorCompactTelemetryBudget(MonitorLayoutPolicy.fieldMonitor(320f, 956f),
            0f, 0f, 86f, 140f, 64f, 48f, 2f, minimumLinkWidth = 51.5f)
        assertTrue(fit.wrapsPower)
        assertTrue(fit.performanceWidth >= 51.5f)
        assertEquals(86f, fit.storageWidth)
        assertEquals(108f, fit.performanceX)
        assertEquals(166f, fit.powerX)
    }

    @Test fun fittedContentKeepsTheExistingSingleRow() {
        val fit = MonitorCompactTelemetryBudget(MonitorLayoutPolicy.fieldMonitor(320f, 956f),
            0f, 0f, 86f, 134f, 64f, 48f, 2f, minimumLinkWidth = 51.5f)
        assertFalse(fit.wrapsPower)
        assertEquals(56f, fit.performanceWidth)
    }

    @Test fun fractionalNativeContentWrapsWithoutRoundingAwayTheClearance() {
        val fit = MonitorCompactTelemetryBudget.pixels(840, 42, 42, 0, 0,
            226, 368, 168, 126, 37, 21, 136)
        assertTrue(fit.wrapsPower)
        assertTrue(fit.performanceWidth >= 136)
    }

    @Test fun fractionalNativeMeasurementsStayIntegralAcrossTheWholeRow() {
        // At2.625 density the legacy158dp row rounds415px, then subtracts168px link and21px gap.
        // A real352px power measure becomes352.00003px after a Float dp round trip.
        val fit = MonitorCompactTelemetryBudget.pixels(840, 42, 42, 0, 0,
            226, 352, 168, 126, 37, 21)
        assertEquals(37, fit.leading)
        assertEquals(226, fit.storageWidth)
        assertEquals(284, fit.performanceX)
        assertEquals(146, fit.performanceWidth)
        assertEquals(451, fit.powerX)
    }

    @Test fun fractionalNativePaddingRetainsOriginalRoundedDecorationWhenItFits() {
        // The original6dp padding resolves16px at2.625, not15px from a second floor.
        val ordinary = MonitorTelemetryPadding.pixels(136, 168, 168, 126, 16)
        assertEquals(168, ordinary.width)
        assertEquals(16, ordinary.padding)
        assertTrue(ordinary.fits)
        val compact = MonitorTelemetryPadding.pixels(136, 146, 168, 126, 16)
        assertEquals(146, compact.width)
        assertEquals(5, compact.padding)
        assertTrue(compact.fits)
    }

    @Test fun compactLongStorageKeepsItsAllocationBeforePerformanceAndRealPower() {
        val fit = MonitorCompactTelemetryBudget(MonitorLayoutPolicy.fieldMonitor(320f, 956f),
            0f, 0f, 86f, 134f, 64f, 44f, 2f)
        assertEquals(14f, fit.leading)
        assertEquals(86f, fit.storageWidth)
        assertEquals(108f, fit.performanceX)
        assertEquals(56f, fit.performanceWidth)
        assertEquals(172f, fit.powerX)
    }

    @Test fun availableRoomPreservesOriginalCornersAndPerformanceStyling() {
        val fit = MonitorCompactTelemetryBudget(MonitorLayoutPolicy.fieldMonitor(320f, 956f),
            0f, 0f, 70f, 134f, 64f, 44f, 2f)
        assertEquals(16f, fit.leading)
        assertEquals(94f, fit.performanceX)
        assertEquals(170f, fit.powerX)
        val pill = MonitorTelemetryPadding(51.167f, fit.performanceWidth, 64f, 44f, 2f)
        assertEquals(64f, pill.width)
        assertEquals(6f, pill.padding)
        assertTrue(pill.fits)
    }

    @Test fun unknownStorageReservesItsFullTargetBeforeTheEightPointGap() {
        val fit = MonitorCompactTelemetryBudget(MonitorLayoutPolicy.fieldMonitor(320f, 956f),
            0f, 0f, 30f, 134f, 64f, 48f, 2f)
        assertEquals(48f, fit.storageWidth)
        assertEquals(fit.leading + 56f, fit.performanceX)
    }

    @Test fun paddingPreservesUnscaledContentOnTwoAndThreePixelLattices() {
        for ((scale, width, padding) in listOf(Triple(2f, 55.5f, 2f), Triple(3f, 56f, 7f / 3f))) {
            val pill = MonitorTelemetryPadding(51.167f, 56f, 64f, 48f, scale)
            assertEquals(width, pill.width)
            assertEquals(padding, pill.padding)
            assertTrue(pill.fits)
        }
        val signal = MonitorTelemetryPadding(34.5f, 56f, 64f, 48f, 2f)
        assertEquals(48f, signal.width)
        assertEquals(6f, signal.padding)
    }

    @Test fun anImpossibleBudgetRetainsContentAndReportsFailureInsteadOfScaling() {
        val pill = MonitorTelemetryPadding(51.167f, 50f, 64f, 48f, 2f)
        assertEquals(51.5f, pill.width)
        assertEquals(0f, pill.padding)
        assertFalse(pill.fits)
    }

    @Test fun absentStorageDoesNotReserveAnInvisibleTargetOrGap() {
        val fit = MonitorCompactTelemetryBudget(MonitorLayoutPolicy.fieldMonitor(320f, 956f),
            0f, 0f, 0f, 134f, 64f, 48f, 2f)
        assertEquals(0f, fit.storageWidth)
        assertEquals(fit.leading, fit.performanceX)
    }

    @Test fun aPunchHoleBoundsStorageSoTheLinkPillEndsBeforeIt() {
        val layout = MonitorLayoutPolicy.fieldMonitor(412f, 915f, safeTop = 52f)
        val hole = MonitorRect(193f, 12f, 26f, 26f)
        val storage = MonitorCompactTelemetryBudget.storageWidthBeforeCutout(layout, hole, 58f, 48f)!!
        // Storage, its 8 dp gap and the 58 dp link end 6 dp before the cutout.
        assertEquals(hole.x - 6f, layout.status.x + storage + 8f + 58f)
    }

    @Test fun aMeasuredWideLinkReservesItsRealWidthBeforeTheCutout() {
        val layout = MonitorLayoutPolicy.fieldMonitor(412f, 915f, safeTop = 52f)
        val hole = MonitorRect(193f, 12f, 26f, 26f)
        val density = Density(1f, 1f)
        val resting = density.legacyStorageWidthPixels(layout, hole, preferredLink = 58, minimumTarget = 48f)
        val wide = density.legacyStorageWidthPixels(layout, hole, preferredLink = 90, minimumTarget = 48f)
        // The extra 32 dp of live text is taken from storage, never from the cutout clearance.
        assertEquals(resting - 32, wide)
        assertTrue(wide < resting)
    }

    /** Z nightly 39422965987: "521GB" painted as "521..." beside a link pill keeping its padding. */
    @Test fun aLinkThatCanDropItsPaddingLeavesThatRoomToStorageBeforeTheCutout() {
        val layout = MonitorLayoutPolicy.fieldMonitor(412f, 915f, safeTop = 52f)
        val hole = MonitorRect(193f, 12f, 26f, 26f)
        val density = Density(1f, 1f)
        val resting = density.legacyStorageWidthPixels(layout, hole, preferredLink = 58, minimumTarget = 48f)
        val yielding = density.legacyStorageWidthPixels(layout, hole, preferredLink = 58, minimumTarget = 48f,
            minimumLink = 46)
        assertEquals(resting + 12, yielding)
        // The link then starts after storage and its gap and still ends 6 dp before the cutout.
        val linkX = layout.status.x + yielding + 8f
        assertEquals(46f, MonitorCompactTelemetryBudget.linkWidthBeforeCutout(layout, hole, linkX))
        assertEquals(null, MonitorCompactTelemetryBudget.linkWidthBeforeCutout(layout, null, linkX))
    }

    @Test fun aWideNotchOrACutoutOutsideTheBandKeepsTheOriginalCorners() {
        val layout = MonitorLayoutPolicy.fieldMonitor(375f, 812f, safeTop = 44f)
        assertEquals(null, MonitorCompactTelemetryBudget.storageWidthBeforeCutout(
            layout, MonitorRect(83f, 0f, 209f, 30f), 58f, 48f))
        assertEquals(null, MonitorCompactTelemetryBudget.storageWidthBeforeCutout(
            layout, MonitorRect(150f, layout.telemetry.maxY + 1f, 20f, 20f), 58f, 48f))
        assertEquals(null, MonitorCompactTelemetryBudget.storageWidthBeforeCutout(layout, null, 58f, 48f))
    }
}
