#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import SwiftUI
    import XCTest

    final class MonitorScopePanelPlacementTests: XCTestCase {
        func testFixedPanelUsesItsWholeBodyWithoutAnInvisibleResizeWell() {
            let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
            let panel = MonitorScopePanelLayout(baseSize: bounds.size, preferredSize: bounds.size,
                center: CGPoint(x: 1000, y: 1000), scale: 1,
                canvas: bounds, movementBounds: bounds, resizable: false)
            XCTAssertEqual(panel.size, bounds.size)
            XCTAssertEqual(panel.center, CGPoint(x: 50, y: 50))
            XCTAssertFalse(panel.resizable)
        }
        func testAllPanelBodiesAndVerticalResizeWellsStayBetweenControlsAtEveryScale() {
            let canvases = [
                CGRect(x: 0, y: 0, width: 402, height: 874),
                CGRect(x: 0, y: 0, width: 874, height: 402),
                CGRect(x: 0, y: 0, width: 667, height: 375),
            ]
            let preferredSizes = [
                MonitorScopePanelSize.waveform, MonitorScopePanelSize.parade,
                MonitorScopePanelSize.histogram, MonitorScopePanelSize.vectorscope,
                MonitorScopePanelSize.trafficLights, MonitorScopePanelSize.ndMeter,
            ]
            for canvas in canvases {
                let clearance = EdgeInsets(top: 96, leading: 70, bottom: 110, trailing: 100)
                let safe = MonitorScopePanelPlacement.bounds(in: canvas, clearance: clearance)
                XCTAssertTrue(MonitorScopePanelPlacement.isUsable(safe))
                for preferred in preferredSizes {
                    for scale in [0.6, 1.0, 1.6] {
                        let size = MonitorScopePanelPlacement.fittedSize(
                            CGSize(
                                width: preferred.width * scale, height: preferred.height * scale),
                            in: safe)
                        for proposal in [
                            CGPoint(x: -500, y: -500), CGPoint(x: 2000, y: 2000),
                            CGPoint(x: canvas.midX, y: canvas.midY),
                        ] {
                            let center = MonitorScopePanelPlacement.clamp(
                                proposal, size: size, in: safe)
                            let gripOrigin = CGPoint(
                                x: center.x + size.width / 2 - 12,
                                y: center.y + size.height / 2 - 44)
                            XCTAssertGreaterThanOrEqual(gripOrigin.x, safe.minX)
                            XCTAssertGreaterThanOrEqual(gripOrigin.y, safe.minY)
                            XCTAssertGreaterThanOrEqual(center.x - size.width / 2, safe.minX)
                            XCTAssertGreaterThanOrEqual(center.y - size.height / 2, safe.minY)
                            XCTAssertLessThanOrEqual(
                                center.x + size.width / 2, safe.maxX)
                            XCTAssertLessThanOrEqual(
                                center.y + size.height / 2
                                    + MonitorScopePanelPlacement.gripBottomExtent,
                                safe.maxY)
                        }
                    }
                }
            }
        }

        func testRotationClampsRestoredPositionWithoutChangingStoredCoordinates() {
            let landscape = CGRect(x: 0, y: 0, width: 874, height: 402)
            let portrait = CGRect(x: 0, y: 0, width: 402, height: 874)
            let stored = MonitorScopeStoredCenter(center: CGPoint(x: 870, y: 400), in: landscape)
            let safe = MonitorScopePanelPlacement.bounds(
                in: portrait,
                clearance: EdgeInsets(top: 100, leading: 70, bottom: 160, trailing: 100))
            let size = MonitorScopePanelPlacement.fittedSize(
                MonitorScopePanelSize.waveform, in: safe)
            let restored = stored.center(in: portrait)
            let fitted = MonitorScopePanelPlacement.clamp(restored, size: size, in: safe)
            XCTAssertLessThan(fitted.x, restored.x)
            XCTAssertLessThan(fitted.y, restored.y)
            XCTAssertEqual(stored.center(in: landscape), CGPoint(x: 870, y: 400))
        }

        func testTinyCanvasIncludesThePartOfTheGripAboveAShrunkenChip() {
            let safe = CGRect(x: 20, y: 30, width: 56, height: 56)
            let size = MonitorScopePanelPlacement.fittedSize(
                MonitorScopePanelSize.ndMeter, in: safe)
            let center = MonitorScopePanelPlacement.clamp(.zero, size: size, in: safe)
            XCTAssertGreaterThanOrEqual(center.x + size.width / 2 - 12, safe.minX)
            XCTAssertGreaterThanOrEqual(center.y + size.height / 2 - 44, safe.minY)
            XCTAssertLessThanOrEqual(center.x + size.width / 2, safe.maxX)
            XCTAssertLessThanOrEqual(center.y + size.height / 2 + 12, safe.maxY)
            XCTAssertFalse(
                MonitorScopePanelPlacement.isUsable(CGRect(x: 0, y: 0, width: 55, height: 55)))
        }

        func testBottomEdgeOpensAndOnlyMainRailLimitsRightPlacement() {
            let canvas = CGRect(x: 0, y: 0, width: 874, height: 402)
            let mainRailLeft: CGFloat = 800
            let right = mainRailLeft
            let safe = MonitorScopePanelPlacement.bounds(
                in: canvas,
                clearance: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: canvas.maxX - right))
            let size = MonitorScopePanelSize.waveform
            let center = MonitorScopePanelPlacement.clamp(
                CGPoint(x: 2000, y: 2000), size: size, in: safe)
            XCTAssertEqual(center.y + size.height / 2, 382, accuracy: 0.01)
            XCTAssertEqual(center.x + size.width / 2, 792, accuracy: 0.01)
            // The visible L extends 2 pt into the 8 pt padding before the protected rail.
            XCTAssertLessThan(center.x + size.width / 2 + 2, mainRailLeft)
        }

        func testPortraitPanelHasEqualLeftAndRightEdgeSpacing() {
            let canvas = CGRect(x: 0, y: 0, width: 402, height: 874)
            let safe = MonitorScopePanelPlacement.bounds(
                in: canvas,
                clearance: EdgeInsets(top: 62, leading: 0, bottom: 120, trailing: 0))
            for preferred in [
                MonitorScopePanelSize.parade, MonitorScopePanelSize.trafficLights,
                MonitorScopePanelSize.ndMeter,
            ] {
                for scale in [0.6, 1.0, 1.6] {
                    let size = MonitorScopePanelPlacement.fittedSize(
                        CGSize(width: preferred.width * scale, height: preferred.height * scale),
                        in: safe)
                    let right = MonitorScopePanelPlacement.clamp(
                        CGPoint(x: 2000, y: 400), size: size, in: safe)
                    let left = MonitorScopePanelPlacement.clamp(
                        CGPoint(x: -2000, y: 400), size: size, in: safe)
                    XCTAssertEqual(right.x + size.width / 2, 394, accuracy: 0.01)
                    XCTAssertEqual(left.x - size.width / 2, 8, accuracy: 0.01)
                    XCTAssertEqual(
                        canvas.maxX - right.x - size.width / 2,
                        left.x - size.width / 2 - canvas.minX, accuracy: 0.01)
                }
            }
        }

        func testNoSpaceIsUnusableAndFittingNeverEnlargesPanel() {
            let empty = MonitorScopePanelPlacement.bounds(
                in: CGRect(x: 0, y: 0, width: 100, height: 100),
                clearance: EdgeInsets(top: 100, leading: 100, bottom: 100, trailing: 100))
            XCTAssertFalse(MonitorScopePanelPlacement.isUsable(empty))
            let roomy = CGRect(x: 0, y: 0, width: 1000, height: 1000)
            XCTAssertEqual(
                MonitorScopePanelPlacement.fittedSize(MonitorScopePanelSize.waveform, in: roomy),
                MonitorScopePanelSize.waveform)
        }
    }
#endif
