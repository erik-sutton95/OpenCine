#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import SwiftUI
    import Testing
    @testable import OpenCineAppKit

    @MainActor @Suite struct MultiviewStageViewportTests {
        @Test func collapsedReaderInsetsUseTheWindowAndPhysicalOrientation() {
            let window = MonitorWindowGeometry(
                size: CGSize(width: 844, height: 390),
                safeArea: EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59))
            let left = MultiviewStageViewport(
                size: window.size, reportedSafeArea: EdgeInsets(), window: window,
                orientation: .landscapeLeft, arrangement: .grid, selected: 0)
            let right = MultiviewStageViewport(
                size: window.size, reportedSafeArea: EdgeInsets(), window: window,
                orientation: .landscapeRight, arrangement: .grid, selected: 0)
            #expect(left.safeArea.leading == 59 && left.safeArea.trailing == 0)
            #expect(right.safeArea.leading == 0 && right.safeArea.trailing == 59)
            #expect(left.safeArea.bottom == 21 && right.safeArea.bottom == 21)
        }

        @Test func partiallyMissingInsetsPreserveEachPhysicalWindowEdge() {
            let viewport = MultiviewStageViewport(
                size: CGSize(width: 390, height: 844),
                reportedSafeArea: EdgeInsets(top: 0, leading: 7, bottom: 40, trailing: 0),
                window: .init(safeArea: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 5)),
                orientation: .portrait, arrangement: .grid, selected: 0)
            #expect(viewport.safeArea.top == 59)
            #expect(viewport.safeArea.leading == 7)
            #expect(viewport.safeArea.bottom == 40)
            #expect(viewport.safeArea.trailing == 5)
        }

        @Test func portraitKeepsAllInsetsAndTabletWindowControlsMoveTheSharedLayout() {
            let portrait = MultiviewStageViewport(
                size: CGSize(width: 390, height: 844), reportedSafeArea: EdgeInsets(),
                window: .init(safeArea: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)),
                orientation: .portrait, arrangement: .centerStage, selected: 1)
            #expect(portrait.safeArea.top == 59 && portrait.safeArea.bottom == 34)
            let size = CGSize(width: 1194, height: 834)
            let safe = EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)
            let plain = MultiviewStageViewport(
                size: size, reportedSafeArea: EdgeInsets(),
                window: .init(size: size, safeArea: safe),
                orientation: .landscapeLeft, arrangement: .grid, selected: 0)
            let controls = MultiviewStageViewport(
                size: size, reportedSafeArea: EdgeInsets(),
                window: .init(size: size, safeArea: safe, topControlInset: 32),
                orientation: .landscapeLeft, arrangement: .grid, selected: 0)
            #expect(controls.layout.sessionControls.y == plain.layout.sessionControls.y + 32)
            #expect(controls.layout.tiles.count == 4)
            #expect(controls.layout.tiles.allSatisfy { $0.maxY <= size.height })
            #expect(controls.size == size)
        }
    }
#endif
