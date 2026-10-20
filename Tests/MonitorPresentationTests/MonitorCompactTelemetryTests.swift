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

    @Test func theDynamicIslandBoundsStorageSoTheLinkPillEndsBeforeIt() throws {
        let layout = FieldMonitorLayout(width: 393, height: 852, safeArea: .init(top: 59))
        let island = try #require(MonitorTopCutout.estimated(width: 393, height: 852, safeTop: 59))
        #expect(island == MonitorRect(x: 133.5, y: 11, width: 126, height: 40))
        let storage = try #require(MonitorCompactTelemetryBudget.storageWidthBeforeCutout(
            layout: layout, topCutout: island, linkWidth: 58, minimumTarget: 44))
        // Storage, its 8 pt gap and the 58 pt link end 6 pt before the island.
        #expect(layout.status.x + storage + 8 + 58 == island.x - 6)
        #expect(storage == 45.5)
    }

    /// Z nightly 39422965987: "521GB" painted as "521..." beside a link pill keeping its padding.
    @Test func aLinkThatDropsItsPaddingLeavesThatRoomToStorageAndStillEndsBeforeTheIsland() throws {
        let layout = FieldMonitorLayout(width: 402, height: 874, safeArea: .init(top: 62))
        let island = try #require(MonitorTopCutout.estimated(width: 402, height: 874, safeTop: 62))
        let resting = try #require(MonitorCompactTelemetryBudget.storageWidthBeforeCutout(
            layout: layout, topCutout: island, linkWidth: 58, minimumTarget: 44))
        let yielding = try #require(MonitorCompactTelemetryBudget.storageWidthBeforeCutout(
            layout: layout, topCutout: island, linkWidth: 46, minimumTarget: 44))
        #expect(yielding == resting + 12)
        // An 11 pt "521GB" readout with its card glyph is 56 pt wide.
        #expect(yielding >= 56)
        let linkX = layout.status.x + yielding + 8
        #expect(MonitorCompactTelemetryBudget.linkWidthBeforeCutout(
            layout: layout, topCutout: island, linkX: linkX) == 46)
        #expect(MonitorCompactTelemetryBudget.linkWidthBeforeCutout(
            layout: layout, topCutout: nil, linkX: linkX) == nil)
    }

    @Test func noCutoutANotchOrALandscapePhoneKeepTheOriginalCorners() {
        let layout = FieldMonitorLayout(width: 375, height: 812, safeArea: .init(top: 44))
        #expect(MonitorTopCutout.estimated(width: 375, height: 812, safeTop: 44) == nil)
        #expect(MonitorTopCutout.estimated(width: 375, height: 667, safeTop: 20) == nil)
        #expect(MonitorTopCutout.estimated(width: 852, height: 393, safeTop: 0) == nil)
        #expect(MonitorTopCutout.estimated(width: 834, height: 1194, safeTop: 24) == nil)
        // A notch-wide housing leaves less than a minimum storage target and the link.
        let notch = MonitorRect(x: 83, y: 0, width: 209, height: 30)
        #expect(MonitorCompactTelemetryBudget.storageWidthBeforeCutout(
            layout: layout, topCutout: notch, linkWidth: 58, minimumTarget: 44) == nil)
        // A housing above or below the telemetry band does not bound it.
        let below = MonitorRect(x: 150, y: layout.telemetry.maxY + 1, width: 20, height: 20)
        #expect(MonitorCompactTelemetryBudget.storageWidthBeforeCutout(
            layout: layout, topCutout: below, linkWidth: 58, minimumTarget: 44) == nil)
    }
}
