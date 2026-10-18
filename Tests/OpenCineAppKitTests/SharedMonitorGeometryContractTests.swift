#if os(iOS)
import MonitorPresentation
import SwiftUI
import Testing

@testable import OpenCineAppKit

/// Joined tests exercise the placement actually used by the common popup view.
/// Feed crop and absent fields cannot move an operator's established drawer well.
@MainActor
struct SharedMonitorGeometryContractTests {
    @Test func portraitRecordingCategoriesUseStatusEdgeAndClearTheSystemRail() {
        let safe = MonitorSafeArea(top: 59, bottom: 34)
        for aspect in [16.0 / 9, 9.0 / 16, 1] {
            for fill in [false, true] {
                let layout = FieldMonitorLayout(width: 393, height: 852, safeArea: safe,
                    sourceAspect: aspect, fill: fill)
                let popup = MonitorCapturePopupContainer(layout: layout, safeArea: safe, top: true) { _ in EmptyView() }
                let placement = popup.placement
                #expect(placement.edge == .top)
                #expect(placement.top == layout.status.maxY + 6)
                #expect(placement.bottom == layout.system.y - 12)
                #expect(placement.maximumHeight == placement.bottom - placement.top)
                #expect(placement.width == 365 && placement.centerX == 196.5)
                #expect(placement.bottom < layout.record.y)
            }
        }
    }

    /// Landscape recording categories float under the one popup top margin, every corner rounded.
    @Test func landscapeRecordingCategoriesKeepThePopupTopMarginAcrossCutoutRotation() {
        for safe in [MonitorSafeArea(leading: 62, bottom: 21),
                     MonitorSafeArea(bottom: 21, trailing: 62)] {
            let layout = FieldMonitorLayout(width: 874, height: 402, safeArea: safe)
            let popup = MonitorCapturePopupContainer(layout: layout, safeArea: safe, top: true) { _ in EmptyView() }
            let placement = popup.placement
            #expect(placement.edge == .top && placement.top == MonitorCapturePopupLayout.topMargin(safeTop: 0))
            #expect(placement.bottom == 402)
            #expect(placement.centerX == 437 && placement.width == 480)
            #expect(placement.topCornerRadius == 16 && placement.bottomCornerRadius == 16)
        }
    }

    @Test func bottomCameraDrawerKeepsItsWellAcrossCropAndAbsentReadouts() {
        let safe = MonitorSafeArea(top: 59, bottom: 34)
        let reference = FieldMonitorLayout(width: 393, height: 852, safeArea: safe)
        let referencePopup = MonitorCapturePopupContainer(layout: reference, safeArea: safe, top: false) { _ in EmptyView() }
        for aspect in [16.0 / 9, 9.0 / 16] {
            for fill in [false, true] {
                for showsValues in [false, true] {
                    let layout = FieldMonitorLayout(width: 393, height: 852, safeArea: safe,
                        sourceAspect: aspect, fill: fill, showsValues: showsValues)
                    let popup = MonitorCapturePopupContainer(layout: layout, safeArea: safe, top: false) { _ in EmptyView() }
                    #expect(popup.placement == referencePopup.placement)
                    #expect(popup.placement.edge == .bottom)
                    #expect(popup.placement.bottom == layout.system.y - 12)
                    #expect(popup.placement.bottomPadding >= safe.bottom)
                }
            }
        }
    }
}
#endif
