import MonitorPresentation
import Testing

/// Floating scopes never rest on the live chrome, yet still reach each screen edge where no
/// control stands (owner hardware pass 2026-10-30, iPad Pro 11-inch: a vectorscope dragged to
/// the right edge ended under DISP and the record button). Same table as Kotlin
/// `MonitorScopeChromeAvoidanceTest`.
struct MonitorScopeChromeAvoidanceTests {
    static let gap = 8.0
    static let grip = 12.0
    static let devices: [(String, Double, Double, MonitorSafeArea)] = [
        ("iPad landscape", 1210, 834, MonitorSafeArea(top: 24, bottom: 20)),
        ("iPad portrait", 834, 1210, MonitorSafeArea(top: 24, bottom: 20)),
        ("phone landscape", 874, 402, MonitorSafeArea(leading: 62, bottom: 21, trailing: 62)),
        ("phone portrait", 402, 874, MonitorSafeArea(top: 62, bottom: 34)),
    ]
    /// Waveform, vectorscope, histogram and traffic lights at their base sizes.
    static let panels: [(Double, Double)] = [(250, 153), (190, 190), (250, 77), (74, 168)]
    static let withoutRecenter = MonitorScopeChrome.all.subtracting(.focusReset)

    struct Scene {
        let layout: FieldMonitorLayout
        let bounds: MonitorRect
        let obstacles: [MonitorRect]
        init(_ width: Double, _ height: Double, _ safe: MonitorSafeArea, fill: Bool,
            chrome: MonitorScopeChrome = .all) {
            layout = FieldMonitorLayout(width: width, height: height, safeArea: safe, fill: fill)
            let inset = layout.scopeClearance(safeArea: safe)
            bounds = MonitorRect(
                x: inset.leading + gap, y: inset.top + gap,
                width: width - inset.leading - inset.trailing - 2 * gap,
                height: height - inset.top - inset.bottom - 2 * gap)
            obstacles = layout.scopeObstacles(chrome)
        }
        /// The resizable panel clamp: the body inside the bounds, the resize strip below it too.
        func clamp(_ point: MonitorScopePoint, _ w: Double, _ h: Double) -> MonitorScopePoint {
            MonitorScopePoint(
                x: min(max(bounds.x + w / 2, point.x), bounds.maxX - w / 2),
                y: min(max(bounds.y + h / 2, point.y), bounds.maxY - h / 2 - grip))
        }
        func drop(_ point: MonitorScopePoint, _ w: Double, _ h: Double) -> MonitorScopePoint {
            MonitorScopeChromeAvoidance.resolve(
                point, width: w, height: h, bottomExtent: grip, avoiding: obstacles, gap: gap
            ) { clamp($0, w, h) }
        }
        /// The panel's body and resize strip keep the gap from every control.
        func isClear(_ center: MonitorScopePoint, _ w: Double, _ h: Double) -> Bool {
            obstacles.allSatisfy { rect in
                center.x + w / 2 <= rect.x - gap + 0.01 || center.x - w / 2 >= rect.maxX + gap - 0.01
                    || center.y + h / 2 + grip <= rect.y - gap + 0.01
                    || center.y - h / 2 >= rect.maxY + gap - 0.01
            }
        }
    }

    /// Corners, the record button, DISP, Settings, Media, the timecode row, the camera values
    /// and the palette: wherever a scope is dropped it ends clear of every control and inside
    /// the movement bounds, in either orientation, fit or fill, on a tablet and a phone.
    @Test func droppedOnAnyControlTheScopeEndsClearOfAllChrome() {
        for (name, width, height, safe) in Self.devices {
            for fill in [false, true] {
                let scene = Scene(width, height, safe, fill: fill)
                let l = scene.layout
                let drops = [
                    MonitorScopePoint(x: width * 10, y: height * 10),
                    MonitorScopePoint(x: width * 10, y: -height * 10),
                    MonitorScopePoint(x: -width * 10, y: height * 10),
                    MonitorScopePoint(x: -width * 10, y: -height * 10),
                    MonitorScopePoint(x: l.record.midX, y: l.record.midY),
                    MonitorScopePoint(x: l.display.midX, y: l.display.midY),
                    MonitorScopePoint(x: l.settings.midX, y: l.settings.midY),
                    MonitorScopePoint(x: l.media.midX, y: l.media.midY),
                    MonitorScopePoint(x: l.status.midX, y: l.status.midY),
                    MonitorScopePoint(x: l.values.midX, y: l.values.midY),
                    MonitorScopePoint(x: l.assists.midX, y: l.assists.midY),
                ]
                for (w, h) in Self.panels {
                    for point in drops {
                        let center = scene.drop(point, w, h)
                        let label = "\(name) fill \(fill) \(w)x\(h) at \(point)"
                        #expect(scene.isClear(center, w, h), "\(label) -> \(center)")
                        #expect(center == scene.clamp(center, w, h), "\(label) left its bounds")
                    }
                }
            }
        }
    }

    /// Dragged past the right edge where no control stands, a scope still ends flush with the
    /// movement bounds: mid-height beside the picture on each device, for a camera without a
    /// recenter key. A phone's rail column leaves room for the histogram there, a tablet's for
    /// the vectorscope.
    @Test func draggedToTheRightEdgeAboveTheControlsTheScopeStaysFlush() {
        for (name, width, height, safe) in Self.devices {
            let (w, h) = name == "phone landscape" ? (250.0, 77.0) : (190.0, 190.0)
            for fill in [false, true] {
                let scene = Scene(width, height, safe, fill: fill, chrome: Self.withoutRecenter)
                let y = scene.layout.portrait ? scene.layout.picture.midY : height / 2
                let center = scene.drop(MonitorScopePoint(x: width * 10, y: y), w, h)
                #expect(abs(center.x + w / 2 - scene.bounds.maxX) < 0.01, "\(name) fill \(fill)")
                #expect(abs(center.y - y) < 0.01, "\(name) fill \(fill) moved off its row")
            }
        }
    }

    /// The vectorscope dragged into the iPad's bottom-right corner rests beside the record
    /// button and DISP, as close to the corner as they allow, not under them.
    @Test func iPadBottomRightCornerRestsNextToTheRecordColumn() {
        let scene = Scene(1210, 834, MonitorSafeArea(top: 24, bottom: 20), fill: false,
            chrome: Self.withoutRecenter)
        let center = scene.drop(MonitorScopePoint(x: 12_000, y: 8_000), 190, 190)
        #expect(scene.isClear(center, 190, 190))
        let right = center.x + 95
        let bottom = center.y + 95 + Self.grip
        let column = min(scene.layout.record.x, scene.layout.display.x)
        #expect(right <= column - Self.gap + 0.01)
        // Flush against the column or the camera values, with nothing nearer the corner.
        #expect(abs(right - (column - Self.gap)) < 0.01 || abs(bottom - (scene.layout.values.y - Self.gap)) < 0.01)
    }

    /// A scope already clear of the chrome stays where the operator put it.
    @Test func aClearScopeKeepsItsCentre() {
        for (_, width, height, safe) in Self.devices {
            let scene = Scene(width, height, safe, fill: false)
            let point = MonitorScopePoint(x: scene.layout.picture.midX, y: scene.layout.picture.midY)
            #expect(scene.drop(point, 74, 100) == point)
        }
    }

    /// A part the surface does not show leaves its space to the scopes: without the rail keys
    /// a scope rests in the corner they held.
    @Test func hiddenChromeFreesItsSpace() {
        let layout = FieldMonitorLayout(width: 1210, height: 834, safeArea: MonitorSafeArea(top: 24, bottom: 20))
        let all = layout.scopeObstacles(.all)
        let bare = layout.scopeObstacles(MonitorScopeChrome.all.subtracting([.record, .display]))
        #expect(all.contains(layout.record) && all.contains(layout.display))
        #expect(!bare.contains(layout.record) && !bare.contains(layout.display))
    }
}
