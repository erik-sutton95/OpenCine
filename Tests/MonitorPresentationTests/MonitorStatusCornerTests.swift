import MonitorPresentation
import Testing

/// The landscape photo monitor: setup values ride the status row's trailing corner, exposure
/// values keep the strip, and neither clips at the smallest supported widths (hardware pass
/// 2026-10-30). Same tables as Kotlin `MonitorStatusCornerTest`.
struct MonitorStatusCornerTests {
    /// A capture value as the monitor lays it out: its natural tile width (value or caption,
    /// whichever is wider, plus padding) and its floor (the whole caption plus padding).
    struct Tile {
        let title: String
        let natural: Double
        let floor: Double
        let group: MonitorCaptureReadoutGroup
    }

    /// Widths measured on the iPhone 16 Pro simulator, 2026-10-30 (point sizes; Android's dp
    /// sizes match within a point): the nine photo values in the Nikon order.
    static let photo: [Tile] = [
        .init(title: "MODE", natural: 48, floor: 44, group: .exposure),
        .init(title: "ISO", natural: 50, floor: 30, group: .exposure),
        .init(title: "SHUTTER", natural: 58, floor: 58, group: .exposure),
        .init(title: "IRIS", natural: 52, floor: 34, group: .exposure),
        .init(title: "DRIVE", natural: 54, floor: 45, group: .setup),
        .init(title: "FOCUS", natural: 47, floor: 47, group: .setup),
        .init(title: "WB", natural: 48, floor: 25, group: .setup),
        .init(title: "METER", natural: 55, floor: 45, group: .exposure),
        .init(title: "PROFILE", natural: 54, floor: 54, group: .setup),
    ]
    /// The leading photo readouts (shots remaining, image area and size, quality) with their
    /// 24 pt spacing, measured on the same run.
    static let leadingWidth = 186.0
    /// The widest values a body reports: "Natural auto" white balance and a long creative profile.
    static let longest: [Double] = [54, 47, 103, 70]

    /// Phones and tablets in landscape: iPhone SE, 13 mini, 16 Pro, 16 Pro Max, a compact
    /// Android phone (640 x 360 dp) and an 11 inch iPad.
    static let landscapes: [(Double, Double, MonitorSafeArea)] = [
        (667, 375, .init()), (812, 375, .init(leading: 50, bottom: 21, trailing: 50)),
        (874, 402, .init(leading: 62, bottom: 21, trailing: 62)),
        (956, 440, .init(leading: 62, bottom: 21, trailing: 62)), (640, 360, .init()),
        (1194, 834, .init(top: 24, bottom: 20)),
    ]

    @Test func aLandscapePhotoRowMovesOnlyTheSetupValuesInOrder() {
        let split = MonitorStatusCorner.split(Self.photo, holdsSetup: true, group: \.group)
        #expect(split.strip.map(\.title) == ["MODE", "ISO", "SHUTTER", "IRIS", "METER"])
        #expect(split.corner.map(\.title) == ["DRIVE", "FOCUS", "WB", "PROFILE"])
        let kept = MonitorStatusCorner.split(Self.photo, holdsSetup: false, group: \.group)
        #expect(kept.strip.map(\.title) == Self.photo.map(\.title) && kept.corner.isEmpty)
    }

    /// Video keeps its clock in the corner, portrait keeps every value in the strip's grid, and
    /// a hidden status row or hidden values leave the strip as it is.
    @Test(arguments: [
        (true, false, true, true, true), (false, false, true, true, false),
        (true, true, true, true, false), (true, false, false, true, false),
        (true, false, true, false, false),
    ])
    func onlyAShownLandscapePhotoRowTakesTheSetupValues(
        photo: Bool, portrait: Bool, status: Bool, values: Bool, expected: Bool
    ) {
        #expect(
            MonitorStatusCorner.holdsSetup(
                photo: photo, portrait: portrait, statusShown: status, valuesShown: values)
                == expected)
    }

    /// At every landscape size the four setup tiles fit beside the leading readouts at their
    /// natural widths, inside the status row and clear of the system buttons, and the five
    /// exposure tiles fit the strip without narrowing. Nine tiles did not fit the SE's strip.
    @Test func bothRowsFitWithoutNarrowingAtEverySize() {
        let split = MonitorStatusCorner.split(Self.photo, holdsSetup: true, group: \.group)
        for (width, height, safe) in Self.landscapes {
            let layout = FieldMonitorLayout(width: width, height: height, safeArea: safe)
            let available = cornerRoom(layout)
            let tiles = MonitorStatusCorner.widths(
                natural: split.corner.map(\.natural), floors: split.corner.map(\.floor),
                available: available)
            #expect(tiles == split.corner.map(\.natural), "\(width)x\(height)")
            let corner = MonitorStatusCorner.width(of: tiles)
            #expect(corner <= available, "\(width)x\(height)")
            let cornerX = layout.status.maxX - layout.recordingReadoutTrailingInset - corner
            #expect(cornerX >= layout.status.x + Self.leadingWidth + MonitorStatusCorner.leadingGap)
            #expect(layout.status.maxX <= layout.settings.x)
            let strip = split.strip.map(\.natural).reduce(0, +) + 16 * Double(split.strip.count - 1)
            #expect(strip <= layout.values.width, "\(width)x\(height)")
        }
        let se = FieldMonitorLayout(width: 667, height: 375)
        let all = Self.photo.map(\.natural).reduce(0, +) + 16 * Double(Self.photo.count - 1)
        #expect(all > se.values.width)
    }

    /// The widest values still fit on a 640 point row without cutting a caption: tiles narrow
    /// toward their captions, never past them, and stay inside the corner's room.
    @Test func theWidestValuesNarrowTowardTheirCaptionsAndNeverPast() {
        let floors = [45.0, 47, 25, 54]
        for (width, height, safe) in Self.landscapes {
            let layout = FieldMonitorLayout(width: width, height: height, safeArea: safe)
            let available = cornerRoom(layout)
            let tiles = MonitorStatusCorner.widths(
                natural: Self.longest, floors: floors, available: available)
            #expect(zip(tiles, floors).allSatisfy { $0 >= $1 - 1e-9 }, "\(width)x\(height)")
            #expect(zip(tiles, Self.longest).allSatisfy { $0 <= $1 + 1e-9 })
            #expect(MonitorStatusCorner.width(of: tiles) <= available + 1e-9, "\(width)x\(height)")
        }
    }

    /// With no room the tiles keep their whole captions; given room they keep natural widths.
    @Test func widthsKeepCaptionsWholeAtAnyRoom() {
        let natural = [80.0, 40, 60]
        let floors = [40.0, 40, 30]
        #expect(MonitorStatusCorner.widths(natural: natural, floors: floors, available: 10) == floors)
        #expect(MonitorStatusCorner.widths(natural: natural, floors: floors, available: 1_000) == natural)
        let squeezed = MonitorStatusCorner.widths(natural: natural, floors: floors, available: 154)
        #expect(abs(MonitorStatusCorner.width(of: squeezed) - 154) < 1e-9)
        #expect(squeezed[1] == 40)
    }

    private func cornerRoom(_ layout: FieldMonitorLayout) -> Double {
        layout.status.width - Self.leadingWidth - MonitorStatusCorner.leadingGap
            - layout.recordingReadoutTrailingInset
    }
}

/// The recenter key follows the camera's motion capability: beside the gimbal cluster when the
/// camera has one, in the feed's trailing bottom corner when it has none (owner request,
/// hardware pass 2026-10-30). Same tables as Kotlin `MonitorStatusCornerTest`.
struct FocusResetPlacementTests {
    static let sizes: [(Double, Double, MonitorSafeArea)] = [
        (667, 375, .init()), (812, 375, .init(leading: 50, bottom: 21, trailing: 50)),
        (874, 402, .init(leading: 62, bottom: 21, trailing: 62)), (640, 360, .init()),
        (1194, 834, .init(top: 24, bottom: 20)),
        (375, 667, .init(top: 20)), (402, 874, .init(top: 62, bottom: 34)),
        (360, 640, .init(top: 24)), (834, 1194, .init(top: 24, bottom: 20)),
    ]

    private func overlaps(_ a: MonitorRect, _ b: MonitorRect) -> Bool {
        a.x < b.maxX && b.x < a.maxX && a.y < b.maxY && b.y < a.maxY
    }

    @Test func aGimbalCameraKeepsTheKeyBesideTheCluster() {
        for (width, height, safe) in Self.sizes {
            let layout = FieldMonitorLayout(width: width, height: height, safeArea: safe)
            #expect(layout.focusReset(motionCluster: true) == layout.focusReset)
            #expect(layout.aeUnlock(motionCluster: true) == layout.aeUnlock)
        }
    }

    @Test(arguments: [false, true])
    func withoutAClusterTheKeyTakesTheFeedsTrailingBottomCorner(fill: Bool) {
        for (width, height, safe) in Self.sizes {
            for aspect in [3.0 / 2, 16.0 / 9, 1] {
                let layout = FieldMonitorLayout(
                    width: width, height: height, safeArea: safe, sourceAspect: aspect, fill: fill,
                    valueCount: 9)
                let key = layout.focusReset(motionCluster: false)
                let size = "\(width)x\(height) \(aspect) \(fill)"
                #expect(key.width == layout.focusReset.width && key.height == layout.focusReset.height)
                // Inside the picture's trailing bottom quarter.
                #expect(key.x >= layout.picture.midX && key.maxX <= layout.picture.maxX, "\(size)")
                #expect(key.y >= layout.picture.midY && key.maxY <= layout.picture.maxY, "\(size)")
                // Clear of every control around that corner.
                var chrome = [
                    layout.values, layout.record, layout.display, layout.settings, layout.media,
                    layout.lock, layout.assists, layout.status,
                ]
                if layout.portrait { chrome += [layout.aspectToggle, layout.system] }
                for rect in chrome where rect.width > 0 {
                    #expect(!overlaps(key, rect), "\(size) \(rect)")
                }
                let unlock = layout.aeUnlock(motionCluster: false)
                #expect(unlock.maxX <= key.x && unlock.y == key.y, "\(size)")
                for rect in chrome + [key] where rect.width > 0 {
                    #expect(!overlaps(unlock, rect), "\(size) \(rect)")
                }
            }
        }
    }
}
