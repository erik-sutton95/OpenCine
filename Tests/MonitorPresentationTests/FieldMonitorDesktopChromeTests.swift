import MonitorPresentation
import Testing

/// The live monitor in a desktop window: the title bar is a toolbar, one status row sits under it
/// and the picture starts below that (spec 2026-11-25-desktop-camera-window-toolbar-design.md).
struct FieldMonitorDesktopChromeTests {
    /// Window content sizes a module window takes: the default 16:10, a wide and a short window, a
    /// square-ish one and a tall one.
    static let windows: [(Double, Double)] = [
        (1000, 625), (1440, 900), (1600, 600), (800, 700), (700, 1000), (480, 360),
    ]
    /// The title bar's height in the window's safe area, and none.
    static let titleBars: [Double] = [0, 52]

    static func desktop(_ width: Double, _ height: Double, titleBar: Double) -> FieldMonitorLayout {
        FieldMonitorLayout(
            width: width, height: height, safeArea: .init(top: titleBar), chrome: .desktop)
    }

    @Test func desktopHasNoLockOrTopStrip() {
        for (width, height) in Self.windows {
            for titleBar in Self.titleBars {
                let layout = Self.desktop(width, height, titleBar: titleBar)
                let label = "\(width)x\(height) title \(titleBar)"
                for rect in [layout.lock, layout.settings, layout.media, layout.gauges, layout.telemetry] {
                    #expect(rect.width == 0 && rect.height == 0, "\(label)")
                }
                // The status row replaces the phone's top strip: full width, right under the title bar.
                #expect(
                    layout.status
                        == MonitorRect(
                            x: 0, y: titleBar, width: width,
                            height: FieldMonitorLayout.desktopStatusRowHeight), "\(label)")
                // A desktop window is never laid out as a phone held upright.
                #expect(!layout.portrait, "\(label)")
            }
        }
        // No lock, gear or media in the picture, even while locked or recording.
        let visibility = MonitorSystemControlsVisibility().resolved(
            locked: true, recording: true, borrowed: false, chrome: .desktop)
        #expect(!visibility.lock && !visibility.settings && !visibility.media)
        #expect(visibility.record && visibility.display)
    }

    /// The picture is centred both ways in the space between the status row and the window's
    /// bottom edge, so the bars are equal top and bottom, or left and right (spec
    /// 2026-11-25-desktop-mac-sized-ui-and-scroll-dials-design.md).
    @Test func desktopPictureIsCentredBelowTheStatusRow() {
        #expect(FieldMonitorLayout.desktopStatusRowHeight == 30)
        for (width, height) in Self.windows {
            for titleBar in Self.titleBars {
                let label = "\(width)x\(height) title \(titleBar)"
                for aspect in [16.0 / 9.0, 1.5] {
                    let layout = FieldMonitorLayout(
                        width: width, height: height, safeArea: .init(top: titleBar), sourceAspect: aspect,
                        chrome: .desktop)
                    let above = layout.picture.y - layout.status.maxY
                    let below = height - layout.picture.maxY
                    #expect(above >= -1e-9, "\(label) \(aspect)")
                    #expect(abs(above - below) < 1e-9, "\(label) \(aspect)")
                    #expect(abs(layout.picture.x - (width - layout.picture.maxX)) < 1e-9, "\(label) \(aspect)")
                    // The controls that stay on the picture stay inside the window.
                    for rect in [layout.record, layout.display, layout.values, layout.assists, layout.stick] {
                        #expect(rect.y >= layout.status.maxY && rect.maxY <= height + 1e-9, "\(label)")
                    }
                }
            }
        }
        // A tall window: the spare height splits above and below the picture.
        #expect(
            Self.desktop(700, 1000, titleBar: 52).picture
                == MonitorRect(x: 0, y: 344.125, width: 700, height: 393.75))
        // A wide window: the picture fills the height under the row and is pillarboxed.
        let wide = Self.desktop(1600, 600, titleBar: 0).picture
        #expect(wide.y == 30 && wide.height == 570)
        #expect(abs(wide.x - 880.0 / 3.0) < 1e-6)
    }

    @Test func desktopPopupsStayInsideThePictureArea() {
        for (width, height) in Self.windows {
            for titleBar in Self.titleBars {
                let layout = Self.desktop(width, height, titleBar: titleBar)
                let label = "\(width)x\(height) title \(titleBar)"
                let window = MonitorSafeArea(top: titleBar)
                let content = layout.contentSafeArea(window)
                #expect(content.top == layout.status.maxY, "\(label)")
                for edge in [MonitorCapturePopupEdge.top, .bottom] {
                    let popup = MonitorCapturePopupLayout(
                        viewportWidth: width, viewportHeight: height, tablet: layout.tablet,
                        safeArea: content, bottomBoundary: layout.values.y, edge: edge)
                    #expect(popup.top >= layout.status.maxY, "\(label) \(edge)")
                }
                #expect(layout.scopeClearance(safeArea: window).top >= layout.status.maxY, "\(label)")
                let dashboard = MonitorCommandDashboardLayout.frame(layout: layout)
                #expect(dashboard.y >= layout.status.maxY, "\(label)")
                #expect(dashboard.x >= 0 && dashboard.maxX <= width, "\(label)")
                #expect(dashboard.width > width / 2, "\(label)")
            }
        }
        // A device keeps its own safe area.
        let phone = FieldMonitorLayout(width: 932, height: 430, safeArea: .init(leading: 59, bottom: 21, trailing: 59))
        #expect(phone.contentSafeArea(.init(leading: 59, bottom: 21, trailing: 59)) == .init(leading: 59, bottom: 21, trailing: 59))
    }

    /// The device layout is what it was before the desktop chrome existed, at a phone and a tablet
    /// landscape size.
    @Test func deviceLayoutIsUnchanged() {
        func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> MonitorRect {
            MonitorRect(x: x, y: y, width: width, height: height)
        }
        func near(_ a: MonitorRect, _ b: MonitorRect) -> Bool {
            abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 && abs(a.width - b.width) < 1e-6
                && abs(a.height - b.height) < 1e-6
        }
        let phone = FieldMonitorLayout(
            width: 932, height: 430, safeArea: .init(leading: 59, bottom: 21, trailing: 59), chrome: .device)
        #expect(!phone.portrait)
        #expect(near(phone.picture, rect(83.77777777777777, 0, 764.4444444444445, 430)))
        #expect(near(phone.status, rect(95.77777777777777, 0, 755.2222222222222, 44)))
        #expect(near(phone.lock, rect(18, 18.75, 48, 48)))
        #expect(near(phone.telemetry, rect(18, 78.75, 58, 68)))
        #expect(near(phone.settings, rect(863, 18.75, 48, 48)))
        #expect(near(phone.media, rect(863, 78.75, 48, 48)))
        #expect(near(phone.record, rect(852, 344, 70, 70)))
        #expect(near(phone.display, rect(863, 288, 48, 48)))
        #expect(near(phone.values, rect(112, 360, 708, 43)))
        #expect(near(phone.assists, rect(18, 289, 89, 110)))
        #expect(near(phone.stick, rect(733, 247, 101, 101)))

        let tablet = FieldMonitorLayout(width: 1180, height: 820, safeArea: .init(top: 24, bottom: 20))
        #expect(near(tablet.picture, rect(0, 78.125, 1180, 663.75)))
        #expect(near(tablet.status, rect(77, 4, 969, 46)))
        #expect(near(tablet.lock, rect(18, 12, 48, 48)))
        #expect(near(tablet.telemetry, rect(18, 71, 64, 76)))
        #expect(near(tablet.settings, rect(1058, 12, 48, 48)))
        #expect(near(tablet.media, rect(1118, 12, 48, 48)))
        #expect(near(tablet.record, rect(1086, 720, 84, 84)))
        #expect(near(tablet.display, rect(1104, 664, 48, 48)))
        #expect(near(tablet.values, rect(126, 751, 928, 43)))
        #expect(near(tablet.assists, rect(18, 680, 89, 110)))
        #expect(near(tablet.stick, rect(967, 638, 101, 101)))
        #expect(tablet.contentSafeArea(.init(top: 24, bottom: 20)) == .init(top: 24, bottom: 20))
        #expect(
            MonitorSystemControlsVisibility().resolved(locked: false, recording: nil, borrowed: false)
                == MonitorSystemControlsVisibility().resolved(
                    locked: false, recording: nil, borrowed: false, chrome: .device))
    }
}
