import MonitorPresentation
import Testing

struct MonitorCompactTelemetryTests {
    @Test func storageStillClearsPowerWhenTheLinkIsUnknown() {
        let fit = MonitorCompactTelemetryBudget(
            layout: FieldMonitorLayout(width: 320, height: 956), safeLeading: 0, safeTrailing: 0,
            storageWidth: 86, powerWidth: 289, linkWidth: 0, minimumTarget: 44, scale: 2)
        #expect(fit.wrapsPower)
        #expect(fit.storageWidth == 86)
    }

    @Test func nativeContentThatExceedsTheSingleRowMovesPowerToASeparateLine() {
        let fit = MonitorCompactTelemetryBudget(
            layout: FieldMonitorLayout(width: 320, height: 956), safeLeading: 0, safeTrailing: 0,
            storageWidth: 86, powerWidth: 140, linkWidth: 64, minimumTarget: 44, scale: 2,
            minimumLinkWidth: 51.5)
        #expect(fit.wrapsPower)
        #expect(fit.performanceWidth >= 51.5)
        #expect(fit.storageWidth == 86)
        #expect(fit.performanceX == 108)
        #expect(fit.powerX == 166)
    }

    @Test func fittedContentKeepsTheExistingSingleRow() {
        let fit = MonitorCompactTelemetryBudget(
            layout: FieldMonitorLayout(width: 320, height: 956), safeLeading: 0, safeTrailing: 0,
            storageWidth: 86, powerWidth: 134, linkWidth: 64, minimumTarget: 44, scale: 2,
            minimumLinkWidth: 51.5)
        #expect(!fit.wrapsPower)
        #expect(fit.performanceWidth == 56)
    }

    @Test func compactLongStorageKeepsItsAllocationBeforePerformanceAndRealPower() {
        let fit = MonitorCompactTelemetryBudget(
            layout: FieldMonitorLayout(width: 320, height: 956), safeLeading: 0, safeTrailing: 0,
            storageWidth: 86, powerWidth: 134, linkWidth: 64, minimumTarget: 44, scale: 2)
        #expect(fit.leading == 14)
        #expect(fit.storageWidth == 86)
        #expect(fit.performanceX == 108)
        #expect(fit.performanceWidth == 56)
        #expect(fit.powerX == 172)
    }

    @Test func availableRoomPreservesOriginalCornersAndPerformanceStyling() {
        let fit = MonitorCompactTelemetryBudget(
            layout: FieldMonitorLayout(width: 320, height: 956), safeLeading: 0, safeTrailing: 0,
            storageWidth: 70, powerWidth: 134, linkWidth: 64, minimumTarget: 44, scale: 2)
        #expect(fit.leading == 16)
        #expect(fit.performanceX == 94)
        #expect(fit.powerX == 170)
        let pill = MonitorTelemetryPadding(contentWidth: 51.167, availableWidth: fit.performanceWidth,
            preferredWidth: 64, minimumTarget: 44, scale: 2)
        #expect(pill.width == 64)
        #expect(pill.padding == 6)
        #expect(pill.fits)
    }

    @Test func unknownStorageReservesItsFullTargetBeforeTheEightPointGap() {
        let fit = MonitorCompactTelemetryBudget(
            layout: FieldMonitorLayout(width: 320, height: 956), safeLeading: 0, safeTrailing: 0,
            storageWidth: 30, powerWidth: 134, linkWidth: 64, minimumTarget: 44, scale: 2)
        #expect(fit.storageWidth == 44)
        #expect(fit.performanceX == fit.leading + 52)
    }

    @Test func paddingPreservesUnscaledContentOnTwoAndThreePixelLattices() {
        for (scale, width, padding) in [(2.0, 55.5, 2.0), (3, 56, 7.0 / 3.0)] {
            let pill = MonitorTelemetryPadding(contentWidth: 51.167, availableWidth: 56,
                preferredWidth: 64, minimumTarget: 44, scale: scale)
            #expect(pill.width == width)
            #expect(pill.padding == padding)
            #expect(pill.fits)
        }
        let signal = MonitorTelemetryPadding(contentWidth: 34.5, availableWidth: 56,
            preferredWidth: 64, minimumTarget: 44, scale: 2)
        #expect(signal.width == 46.5)
        #expect(signal.padding == 6)
    }

    @Test func nativeTargetFloorSurvivesWhenItExceedsTheDrawnLabel() {
        let pill = MonitorTelemetryPadding(contentWidth: 34.5, availableWidth: 56,
            preferredWidth: 64, minimumTarget: 48, scale: 2)
        #expect(pill.width == 48)
        #expect(pill.fits)
    }

    @Test func anImpossibleBudgetRetainsContentAndReportsFailureInsteadOfScaling() {
        let pill = MonitorTelemetryPadding(contentWidth: 51.167, availableWidth: 50,
            preferredWidth: 64, minimumTarget: 44, scale: 2)
        #expect(pill.width == 51.5)
        #expect(pill.padding == 0)
        #expect(!pill.fits)
    }

    @Test func absentStorageDoesNotReserveAnInvisibleTargetOrGap() {
        let fit = MonitorCompactTelemetryBudget(
            layout: FieldMonitorLayout(width: 320, height: 956), safeLeading: 0, safeTrailing: 0,
            storageWidth: 0, powerWidth: 134, linkWidth: 64, minimumTarget: 44, scale: 2)
        #expect(fit.storageWidth == 0)
        #expect(fit.performanceX == fit.leading)
    }
}
