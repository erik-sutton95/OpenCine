#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import SwiftUI
    import XCTest

    /// One table for the movable scope panels: every panel's base size and operator scale go
    /// through the same centring and sizing math.
    final class MonitorScopePanelCenteringTests: XCTestCase {
        private struct Panel {
            let name: String
            let baseSize: CGSize
            let clampedScale: (Double) -> Double
            /// Literal sizes the per-scope tests pinned before the merge.
            let pinnedSizes: [(scale: Double, size: CGSize)]
        }

        private let panels: [Panel] = [
            Panel(
                name: "vectorscope", baseSize: MonitorScopePanelSize.vectorscope,
                clampedScale: MonitorVectorscopeOptions.clampedScale,
                pinnedSizes: [
                    (1, CGSize(width: 190, height: 190)), (2, CGSize(width: 304, height: 304)),
                    (0.6, CGSize(width: 114, height: 114)),
                ]),
            Panel(
                name: "waveform", baseSize: MonitorScopePanelSize.waveform,
                clampedScale: MonitorWaveformOptions.clampedScale,
                pinnedSizes: [
                    (1, CGSize(width: 250, height: 153)), (1.4, CGSize(width: 350, height: 214)),
                ]),
            Panel(
                name: "parade", baseSize: MonitorScopePanelSize.parade,
                clampedScale: MonitorParadeOptions.clampedScale,
                pinnedSizes: [(2, CGSize(width: 400, height: 245))]),
            Panel(
                name: "histogram", baseSize: MonitorScopePanelSize.histogram,
                clampedScale: MonitorHistogramOptions.clampedScale,
                pinnedSizes: [
                    (0.7, CGSize(width: (250 * 0.7).rounded(), height: (77 * 0.7).rounded()))
                ]),
            Panel(
                name: "traffic lights", baseSize: MonitorScopePanelSize.trafficLights,
                clampedScale: MonitorScopePanelCentering.clampedScale,
                pinnedSizes: [
                    (1.2, CGSize(width: (74 * 1.2).rounded(), height: (168 * 1.2).rounded()))
                ]),
            Panel(
                name: "ND meter", baseSize: MonitorScopePanelSize.ndMeter,
                clampedScale: MonitorScopePanelCentering.clampedScale,
                pinnedSizes: [(1, CGSize(width: 84, height: 30))]),
        ]

        func testStoredCenterRoundTripsAsFractions() {
            let samples: [(center: CGPoint, bounds: CGRect)] = [
                (CGPoint(x: 750, y: 125), CGRect(x: 0, y: 0, width: 1000, height: 500)),
                (CGPoint(x: 184, y: 146), CGRect(x: 0, y: 0, width: 874, height: 402)),
                (CGPoint(x: 90, y: 70), CGRect(x: 10, y: 20, width: 400, height: 200)),
                (CGPoint(x: 110, y: 70), CGRect(x: 10, y: 20, width: 200, height: 100)),
                (CGPoint(x: 60, y: 70), CGRect(x: 10, y: 20, width: 200, height: 100)),
                (CGPoint(x: 80, y: 160), CGRect(x: 0, y: 0, width: 200, height: 200)),
            ]
            for sample in samples {
                let label = "\(sample.center) in \(sample.bounds)"
                let stored = MonitorScopeStoredCenter(center: sample.center, in: sample.bounds)
                XCTAssertEqual(
                    stored.xFraction,
                    Double((sample.center.x - sample.bounds.minX) / sample.bounds.width),
                    accuracy: 1e-9, label)
                XCTAssertEqual(
                    stored.yFraction,
                    Double((sample.center.y - sample.bounds.minY) / sample.bounds.height),
                    accuracy: 1e-9, label)
                let restored = stored.center(in: sample.bounds)
                XCTAssertEqual(restored.x, sample.center.x, accuracy: 0.001, label)
                XCTAssertEqual(restored.y, sample.center.y, accuracy: 0.001, label)
            }
        }

        func testUnplacedPanelStartsAtCanvasCenterClearOfChrome() {
            let canvases: [(bounds: CGRect, feed: CGRect)] = [
                (
                    CGRect(x: 0, y: 0, width: 874, height: 402),
                    CGRect(x: 59, y: 0, width: 714.7, height: 402)
                ),
                (
                    CGRect(x: 0, y: 0, width: 800, height: 400),
                    CGRect(x: 40, y: 20, width: 720, height: 360)
                ),
            ]
            let clearance = EdgeInsets(top: 60, leading: 0, bottom: 72, trailing: 0)
            for panel in panels {
                for canvas in canvases {
                    let label = "\(panel.name) in \(canvas.bounds)"
                    let bounds = canvas.bounds
                    let size = panel.baseSize
                    let center = MonitorScopePanelCentering.defaultCenter(
                        size: size, bounds: bounds)
                    XCTAssertEqual(center.x, bounds.midX, accuracy: 0.05, label)
                    XCTAssertEqual(center.y, bounds.midY, accuracy: 0.05, label)
                    let clamped = MonitorScopePanelCentering.clamp(center, size: size, in: bounds)
                    XCTAssertEqual(clamped.x, center.x, accuracy: 0.01, label)
                    XCTAssertEqual(clamped.y, center.y, accuracy: 0.01, label)
                    XCTAssertGreaterThan(center.y, canvas.feed.minY, label)
                    XCTAssertGreaterThan(center.y, clearance.top, label)
                    XCTAssertGreaterThanOrEqual(
                        center.y - size.height / 2, clearance.top + 10 - 0.5, label)
                    XCTAssertGreaterThanOrEqual(center.x - size.width / 2, bounds.minX - 0.5, label)
                    XCTAssertLessThanOrEqual(center.x + size.width / 2, bounds.maxX + 0.5, label)
                    let assistTop = bounds.maxY - clearance.bottom
                    XCTAssertLessThan(center.y + size.height / 2, assistTop, label)
                    XCTAssertGreaterThan(assistTop - (center.y + size.height / 2), 8, label)
                }
            }
        }

        func testClampKeepsThePanelInsideTheBounds() {
            let clamps: [(bounds: CGRect, size: CGSize, point: CGPoint, expected: CGPoint)] = [
                (
                    CGRect(x: 0, y: 0, width: 400, height: 300), CGSize(width: 100, height: 80),
                    CGPoint(x: -20, y: 900), CGPoint(x: 50, y: 260)
                ),
                (
                    CGRect(x: 0, y: 0, width: 400, height: 200), CGSize(width: 100, height: 50),
                    CGPoint(x: -20, y: 400), CGPoint(x: 50, y: 175)
                ),
                (
                    CGRect(x: 0, y: 0, width: 200, height: 200), CGSize(width: 74, height: 168),
                    CGPoint(x: -40, y: 400), CGPoint(x: 37, y: 116)
                ),
                (
                    CGRect(x: 0, y: 0, width: 200, height: 200), CGSize(width: 84, height: 30),
                    CGPoint(x: -40, y: 400), CGPoint(x: 42, y: 185)
                ),
            ]
            for row in clamps {
                let clamped = MonitorScopePanelCentering.clamp(
                    row.point, size: row.size, in: row.bounds)
                XCTAssertEqual(clamped.x, row.expected.x, accuracy: 0.05, "clamp \(row.size)")
                XCTAssertEqual(clamped.y, row.expected.y, accuracy: 0.05, "clamp \(row.size)")
            }
        }

        func testResolvedCenterPrefersSessionThenStoredThenDefault() {
            let fixtures:
                [(
                    bounds: CGRect, size: CGSize, fallback: CGPoint, stored: CGPoint,
                    session: CGPoint
                )] = [
                    (
                        CGRect(x: 0, y: 0, width: 400, height: 300), CGSize(width: 100, height: 80),
                        CGPoint(x: 80, y: 80), CGPoint(x: 200, y: 150), CGPoint(x: 120, y: 110)
                    ),
                    // resolvedCenter clamps every source; the fallback must fit the panel
                    // (half-size 125 x 76.5) to survive unchanged.
                    (
                        CGRect(x: 0, y: 0, width: 800, height: 400),
                        CGSize(width: 250, height: 153),
                        CGPoint(x: 150, y: 100), CGPoint(x: 300, y: 120), CGPoint(x: 400, y: 200)
                    ),
                    (
                        CGRect(x: 0, y: 0, width: 400, height: 200), CGSize(width: 40, height: 20),
                        CGPoint(x: 20, y: 10), CGPoint(x: 200, y: 100), CGPoint(x: 80, y: 60)
                    ),
                    (
                        CGRect(x: 0, y: 0, width: 200, height: 200), CGSize(width: 74, height: 168),
                        CGPoint(x: 50, y: 100), CGPoint(x: 100, y: 110), CGPoint(x: 80, y: 90)
                    ),
                    (
                        CGRect(x: 0, y: 0, width: 200, height: 200), CGSize(width: 84, height: 30),
                        CGPoint(x: 50, y: 40), CGPoint(x: 80, y: 160), CGPoint(x: 90, y: 40)
                    ),
                ]
            func resolved(
                _ session: CGPoint?, _ stored: CGPoint?,
                _ f: (
                    bounds: CGRect, size: CGSize, fallback: CGPoint, stored: CGPoint,
                    session: CGPoint
                )
            ) -> CGPoint {
                MonitorScopePanelCentering.resolvedCenter(
                    session: session,
                    stored: stored.map { MonitorScopeStoredCenter(center: $0, in: f.bounds) },
                    defaultCenter: f.fallback, size: f.size, bounds: f.bounds)
            }
            for f in fixtures {
                let label = "\(f.size)"
                let fromSession = resolved(f.session, f.stored, f)
                XCTAssertEqual(fromSession.x, f.session.x, accuracy: 0.001, label)
                XCTAssertEqual(fromSession.y, f.session.y, accuracy: 0.001, label)
                let fromStored = resolved(nil, f.stored, f)
                XCTAssertEqual(fromStored.x, f.stored.x, accuracy: 0.001, label)
                XCTAssertEqual(fromStored.y, f.stored.y, accuracy: 0.001, label)
                let fromDefault = resolved(nil, nil, f)
                XCTAssertEqual(fromDefault.x, f.fallback.x, accuracy: 0.001, label)
                XCTAssertEqual(fromDefault.y, f.fallback.y, accuracy: 0.001, label)
            }
        }

        func testScaleClampAndPanelSizeRoundBaseTimesScale() {
            let scales: [(Double, Double)] = [
                (0.01, 0.6), (0.2, 0.6), (1, 1), (1.1, 1.1), (2, 1.6), (3, 1.6), (99, 1.6),
            ]
            for panel in panels {
                let size = {
                    MonitorScopePanelCentering.panelSize(
                        panel.baseSize, scale: panel.clampedScale($0))
                }
                XCTAssertEqual(size(1), panel.baseSize, panel.name)
                for (input, expected) in scales {
                    XCTAssertEqual(
                        panel.clampedScale(input), expected, accuracy: 1e-12,
                        "\(panel.name) \(input)")
                    XCTAssertEqual(
                        size(input),
                        CGSize(
                            width: (panel.baseSize.width * expected).rounded(),
                            height: (panel.baseSize.height * expected).rounded()),
                        "\(panel.name) size at \(input)")
                }
                for pinned in panel.pinnedSizes {
                    XCTAssertEqual(size(pinned.scale), pinned.size, "\(panel.name) \(pinned.scale)")
                }
            }
            XCTAssertEqual(MonitorHistogramOptions(scale: 0.01).scale, 0.6)
        }

        // Moved from both iOS apps' VectorscopeAssistTests (their copies of these helpers had no
        // other caller and are gone).
        func testPlotSquareCentresInsideScopePlotRect() {
            let size = CGSize(width: 190, height: 190)
            let plot = MonitorScopeGeometry.plotRect(size, top: 26)
            let square = MonitorScopeGeometry.vectorscopeSquare(in: size)
            XCTAssertEqual(square.width, square.height, accuracy: 0.01)
            XCTAssertEqual(square.midX, plot.midX, accuracy: 0.01)
            XCTAssertEqual(square.midY, plot.midY, accuracy: 0.01)
            XCTAssertEqual(square.width, min(plot.width, plot.height), accuracy: 0.01)
        }
    }
#endif
