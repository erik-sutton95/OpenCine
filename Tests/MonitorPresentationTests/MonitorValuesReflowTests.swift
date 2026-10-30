import MonitorPresentation
import Testing

/// The open View Assist palette keeps every camera value readable and tappable beside it
/// (owner decision 2026-10-28, hardware pass A2; the values used to hide under the plate).
/// Same tables as Kotlin `MonitorValuesReflowTest`.
struct MonitorValuesReflowTests {
    /// Phones and tablets in landscape: iPhone SE, 13 mini, 16 Pro, 16 Pro Max, a compact
    /// Android phone (640 x 360 dp), an 11 inch and a 13 inch iPad.
    static let landscapes: [(Double, Double, MonitorSafeArea)] = [
        (667, 375, .init()), (812, 375, .init(leading: 50, bottom: 21, trailing: 50)),
        (874, 402, .init(leading: 62, bottom: 21, trailing: 62)),
        (956, 440, .init(leading: 62, bottom: 21, trailing: 62)), (640, 360, .init()),
        (1194, 834, .init(top: 24, bottom: 20)), (1366, 1024, .init(top: 24, bottom: 20)),
    ]
    /// Tool catalogs from a short custom set to every tool, and the strip's value counts: a
    /// landscape photo strip (exposure values) to a full video strip.
    static let toolCounts = [4, 8, 12, 16, 20]
    static let valueCounts = [3, 4, 5, 6, 7]

    private func overlaps(_ a: MonitorRect, _ b: MonitorRect) -> Bool {
        a.width > 0 && a.height > 0 && b.width > 0 && b.height > 0
            && a.x < b.maxX && b.x < a.maxX && a.y < b.maxY && b.y < a.maxY
    }

    /// The trailing corner's controls as the live monitor draws them, for either motion capability.
    private func corner(_ layout: FieldMonitorLayout, motion: Bool) -> [MonitorRect] {
        let own = [layout.focusReset(motionCluster: motion), layout.aeUnlock(motionCluster: motion)]
        return motion ? own + [layout.stick, layout.zoom, layout.gimbal, layout.headTrack] : own
    }

    /// With the plate open no tile lies under the plate (as the palette draws it, narrowed to the
    /// reflow's width) or under a corner control, every value has a tile inside the screen and
    /// left of the rail, and every tile keeps its minimum width: all of them fit, none scroll.
    @Test func theOpenPaletteCoversNoValueAndEveryValueFits() {
        for (width, height, safe) in Self.landscapes {
            let layout = FieldMonitorLayout(width: width, height: height, safeArea: safe)
            for tools in Self.toolCounts {
                for count in Self.valueCounts {
                    for motion in [false, true] {
                        let label = "\(width)x\(height) \(tools) tools \(count) values motion \(motion)"
                        let reflow = MonitorValuesReflow.fieldMonitor(
                            layout, toolCount: tools, valueCount: count,
                            cornerControls: MonitorValuesReflow.cornerControls(layout, motionCluster: motion))
                        #expect(reflow.applies, "\(label)")
                        #expect(!reflow.scrolls, "\(label)")
                        let plate = MonitorAssistPaletteLayout.fieldMonitorFootprint(
                            layout, toolCount: tools, safeTop: 0, expanded: true,
                            maximumWidth: reflow.paletteWidth)
                        let tiles = reflow.tiles
                        #expect(tiles.count == count, "\(label)")
                        for tile in tiles {
                            #expect(!overlaps(tile, plate), "\(label) plate")
                            for control in corner(layout, motion: motion) {
                                #expect(!overlaps(tile, control), "\(label) corner control")
                            }
                            #expect(tile.maxX <= layout.values.maxX + 1e-9, "\(label) rail")
                            #expect(tile.maxY <= layout.values.maxY + 1e-9 && tile.y >= 0, "\(label)")
                            #expect(
                                tile.width >= MonitorValuesReflow.minimumTileWidth(tablet: layout.tablet) - 1e-9,
                                "\(label) width")
                        }
                        for (index, tile) in tiles.enumerated() {
                            for other in tiles[(index + 1)...] { #expect(!overlaps(tile, other), "\(label)") }
                        }
                        // The plate keeps two tool columns and never grows past its catalog.
                        let collapsed = MonitorAssistPaletteLayout.fieldMonitorFootprint(
                            layout, toolCount: tools, safeTop: 0, expanded: false)
                        let catalog = MonitorAssistPaletteLayout.fieldMonitorFootprint(
                            layout, toolCount: tools, safeTop: 0, expanded: true)
                        #expect(plate.width >= min(catalog.width, collapsed.width + 54) - 1e-9, "\(label)")
                        #expect(plate.width <= catalog.width + 1e-9, "\(label)")
                    }
                }
            }
        }
    }

    /// A roomy screen keeps the full catalog and the values in one row beside it.
    @Test func aRoomyScreenKeepsTheWholeCatalogAndOneRow() {
        let layout = FieldMonitorLayout(width: 1366, height: 1024, safeArea: .init(top: 24, bottom: 20))
        let reflow = MonitorValuesReflow.fieldMonitor(
            layout, toolCount: 16, valueCount: 6,
            cornerControls: MonitorValuesReflow.cornerControls(layout, motionCluster: false))
        let catalog = MonitorAssistPaletteLayout.fieldMonitorFootprint(
            layout, toolCount: 16, safeTop: 0, expanded: true)
        #expect(reflow.paletteWidth == catalog.width)
        #expect(reflow.rows == [6])
    }

    /// Closed, the strip keeps its own frame; portrait never moves it (the plate grows upward,
    /// above the values), and nothing moves without values or tools.
    @Test func theClosedPaletteAndPortraitKeepTheStrip() {
        for (width, height, safe) in Self.landscapes {
            let landscape = FieldMonitorLayout(width: width, height: height, safeArea: safe)
            let reflow = MonitorValuesReflow.fieldMonitor(
                landscape, toolCount: 16, valueCount: 5,
                cornerControls: MonitorValuesReflow.cornerControls(landscape, motionCluster: false))
            #expect(reflow.values(open: false, closed: landscape.values) == landscape.values)
            let portrait = FieldMonitorLayout(
                width: height, height: width, safeArea: .init(top: safe.leading, bottom: safe.bottom))
            let upright = MonitorValuesReflow.fieldMonitor(
                portrait, toolCount: 16, valueCount: 5,
                cornerControls: MonitorValuesReflow.cornerControls(portrait, motionCluster: false))
            #expect(!upright.applies)
            #expect(upright.values(open: true, closed: portrait.values) == portrait.values)
            let empty = MonitorValuesReflow.fieldMonitor(
                landscape, toolCount: 16, valueCount: 0, cornerControls: [])
            #expect(empty.values(open: true, closed: landscape.values) == landscape.values)
        }
    }

    /// Opening a value (its popup, or its press and slide preview) collapses the plate; the value
    /// under the finger stays put until that ends, and the strip returns after it.
    @Test func aValueOpenedBesideThePlateStaysUntilItsPopupEnds() {
        var reflowed = false
        func step(open: Bool, presented: Bool) -> Bool {
            reflowed = MonitorValuesReflow.reflowed(
                paletteOpen: open, capturePresented: presented, reflowed: reflowed)
            return reflowed
        }
        #expect(step(open: true, presented: false))
        #expect(step(open: false, presented: true), "the plate collapses as the preview begins")
        #expect(step(open: false, presented: true))
        #expect(!step(open: false, presented: false), "the strip returns when the preview ends")
        // A popup opened with the plate closed never moves the strip.
        #expect(!step(open: false, presented: true))
    }
}
