import Foundation

public struct MonitorRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public init(x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0) {
        self.x = x
        self.y = y
        self.width = max(0, width)
        self.height = max(0, height)
    }
}

extension MonitorRect {
    /// The largest rect of `aspect` (width over height) centred inside this one.
    /// Mirrors Kotlin `MonitorRect.fittedContent`.
    func fitting(aspect: Double) -> MonitorRect {
        guard aspect.isFinite, aspect > 0, height > 0 else { return self }
        if width / height > aspect {
            let fittedWidth = height * aspect
            return MonitorRect(
                x: x + (width - fittedWidth) / 2, y: y, width: fittedWidth, height: height)
        }
        let fittedHeight = width / aspect
        return MonitorRect(
            x: x, y: y + (height - fittedHeight) / 2, width: width, height: fittedHeight)
    }
}

public struct MonitorSafeArea: Equatable, Sendable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double
    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }
}

/// Device-independent geometry from the Field Monitor design. Viewport and
/// real window insets are inputs; camera brands and marketed device names are
/// deliberately absent. No drawing, observation, timers, or camera I/O.
/// Operator choice for the on-feed gimbal joystick diameter.
public enum MonitorJoystickSize: String, CaseIterable, Sendable {
    case small, medium, large

    public var side: Double {
        switch self {
        case .small: 88
        case .medium: 101
        case .large: 116
        }
    }

    public var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    public static func parse(_ raw: String?) -> Self { raw.flatMap(Self.init(rawValue:)) ?? .medium }
    public static func fromLabel(_ label: String) -> Self {
        allCases.first { $0.label == label } ?? .medium
    }
}

/// Where the live monitor runs. `device` is a phone or tablet screen. `desktop` is a window on a
/// computer whose title bar is a toolbar holding Settings, Media and the take: one status row sits
/// under the title bar, the picture starts below it, and there is no interface lock and no top
/// strip, gear or media key on the picture. Desktop is Mac only, so it has no Kotlin twin.
public enum MonitorChromeStyle: Equatable, Sendable {
    case device
    case desktop
}

public struct FieldMonitorLayout: Equatable, Sendable {
    /// The desktop status row's height, under the title bar (`MonitorChromeStyle.desktop`).
    public static let desktopStatusRowHeight = 30.0
    /// The desktop take band's height (`take`): a phone's landscape status row.
    public static let takeBandHeight = 44.0
    /// Space between the take and the picture's trailing edge, as on a phone in landscape.
    public static let takeTrailingInset = 12.0
    /// Space between the Settings and Media system buttons.
    public static let settingsMediaGap = 12.0
    /// Default on-feed gimbal joystick diameter.
    public static let stickSide = MonitorJoystickSize.medium.side
    /// The smallest touch target a chrome control is padded to (Apple's 44 pt minimum).
    public static let minimumTapTarget = 44.0
    /// The drawn height of a telemetry gauge pill (link, phone and camera battery).
    public static func telemetryGaugeHeight(tablet: Bool) -> Double { tablet ? 22 : 20 }
    /// Space between the landscape lock and the gauge column under it: the link pill's padded
    /// touch target, centred on its drawn pill, must clear the lock's.
    public static func landscapeGaugeGap(tablet: Bool) -> Double {
        max(6, (minimumTapTarget - telemetryGaugeHeight(tablet: tablet)) / 2)
    }
    /// Camera values per row: three on a phone in portrait, else one row.
    /// Mirrors Kotlin `MonitorLayoutPolicy.valueColumns`.
    public static func valueColumns(count: Int, portrait: Bool, tablet: Bool) -> Int {
        portrait && !tablet ? 3 : max(1, count)
    }
    /// Space one more row of camera values adds: a 34 pt tile and the grid's 8 pt gap.
    public static let valueRowPitch = 42.0
    /// The portrait camera-value band. A phone holds two rows and grows a row pitch for each
    /// further row; a tablet keeps one row. A nil count keeps the two-row band.
    /// Mirrors Kotlin `MonitorLayoutPolicy.portraitValuesHeight`.
    public static func portraitValuesHeight(count: Int?, tablet: Bool) -> Double {
        if tablet { return 43 }
        let columns = valueColumns(count: count ?? 0, portrait: true, tablet: false)
        let rows = count.map { (max(1, $0) + columns - 1) / columns } ?? 2
        return 74 + Double(max(0, rows - 2)) * valueRowPitch
    }

    public let viewport: MonitorRect
    public let picture: MonitorRect
    public let status: MonitorRect
    /// Desktop only (empty on a device, where the status row carries it): the band across the
    /// picture's top edge whose trailing end holds the take, STBY or REC and the timecode, where a
    /// phone or tablet in landscape shows them. It is as tall as a phone's status row.
    public let take: MonitorRect
    /// Keep the landscape tally and clock inside the picture without moving
    /// them off the format row's vertical center or shrinking its touch targets.
    public var recordingReadoutTrailingInset: Double {
        portrait ? 0 : max(8, status.maxX - picture.maxX + 12)
    }
    /// The rect the live stream control hangs under (`LiveStreamOverlayPlacement`): the status row
    /// on a device, the take band in a desktop window, so the control never covers the take.
    public var liveStreamDeck: MonitorRect { chrome == .desktop ? take : status }
    public let values: MonitorRect
    public let system: MonitorRect
    public let lock: MonitorRect
    public let gauges: MonitorRect
    /// Live telemetry render bounds; gauges retains the prior corner geometry for existing compositions.
    public let telemetry: MonitorRect
    public let settings: MonitorRect
    public let media: MonitorRect
    public let record: MonitorRect
    public let display: MonitorRect
    public let assists: MonitorRect
    public let stick: MonitorRect
    public let zoom: MonitorRect
    public let gimbal: MonitorRect
    /// Compass Head Lock control, trailing-aligned above the stick/zoom cluster.
    public let headTrack: MonitorRect
    public let aspectToggle: MonitorRect
    public let focusReset: MonitorRect
    public let portrait: Bool
    public let tablet: Bool
    public let fillsPicture: Bool
    /// Device or desktop. In desktop `status` is the status row under the title bar, and `lock`,
    /// `settings`, `media`, `gauges` and `telemetry` are empty: the toolbar and the status row
    /// carry them.
    public let chrome: MonitorChromeStyle

    /// The portrait header reserves a telemetry band even when immersive insets are small.
    /// This changes chrome only; the picture keeps its native safe-area anchor.
    public static func portraitHeaderSafeTop(width: Double, height: Double, safeTop: Double) -> Double {
        height > width && width < 600 ? max(44, safeTop) : safeTop
    }

    public init(
        width: Double, height: Double, safeArea: MonitorSafeArea = .init(),
        sourceAspect: Double = 16 / 9, fill: Bool = false, showsValues: Bool = true,
        topControlInset: Double = 0, joystick: MonitorJoystickSize = .medium, valueCount: Int? = nil,
        chrome: MonitorChromeStyle = .device
    ) {
        let stickSide = joystick.side
        let w = max(1, width.isFinite ? width : 1)
        let h = max(1, height.isFinite ? height : 1)
        let aspect = sourceAspect.isFinite && sourceAspect > 0 ? sourceAspect : 16 / 9
        let desktop = chrome == .desktop
        // A desktop window's buttons sit in its title bar, above the safe area.
        let controlInset = desktop ? 0 : max(0, min(h, topControlInset.isFinite ? topControlInset : 0))
        // Desktop: the title bar (the window's top safe area) and the status row under it.
        let titleBar = desktop ? max(0, min(h, safeArea.top.isFinite ? safeArea.top : 0)) : 0
        let desktopBand = desktop ? min(h - 1, titleBar + Self.desktopStatusRowHeight) : 0
        self.chrome = chrome
        viewport = .init(width: w, height: h)
        portrait = !desktop && h > w
        tablet = min(w, h) >= 600
        let rec = tablet ? 84.0 : 70.0
        let button = MonitorSystemButtonMetrics.side(tablet: tablet)
        let hasHome = safeArea.bottom > 0
        let edge = 14.0
        let floor: Double
        if portrait {
            let systemH = tablet ? 116.0 : 100.0
            // Record still clears the home indicator; the whole portrait stack sits low.
            let systemY = max(0, h - max(0, safeArea.bottom - 24) - systemH)
            system = .init(y: systemY, width: w, height: h - systemY)
            let valuesH = showsValues ? Self.portraitValuesHeight(count: valueCount, tablet: tablet) : 0
            let valuesY = systemY - 8 - valuesH
            values = .init(x: edge, y: valuesY + 4, width: w - 28, height: valuesH)
            floor = valuesY - (showsValues ? 8 : 0)
            fillsPicture = fill || aspect < 1
            let ratio = fillsPicture ? min(aspect, 9 / 16) : aspect
            // STBY / clock / REC SETUP sit just below the notch, independent of the feed.
            let statusH = tablet ? 52.0 : 44.0
            let headerLift = tablet ? 0.0 : 6.0
            let headerSafeTop = Self.portraitHeaderSafeTop(width: w, height: h, safeTop: safeArea.top)
            let headerLeading = tablet ? edge : max(16, safeArea.leading + 8)
            let headerTrailing = tablet ? edge : max(16, safeArea.trailing + 8)
            status = .init(
                x: headerLeading, y: max(0, headerSafeTop - headerLift) + controlInset,
                width: max(0, w - headerLeading - headerTrailing), height: statusH)
            // Telemetry clearance moves chrome only; retain the existing picture's framing anchor.
            let pictureAnchor = max(0, safeArea.top) + controlInset
            let ceiling = pictureAnchor + statusH
            let pillarbox = tablet && w / ratio > max(0, floor - ceiling)
            let pictureH = pillarbox ? max(1, floor - ceiling) : w / ratio
            let pictureW = pillarbox ? pictureH * ratio : w
            var pictureY: Double
            var verticalRect: MonitorRect?
            if aspect < 1, !pillarbox {
                // A vertical camera is shown whole: fit it above the opaque system
                // bar (the status row is a transparent overlay and may sit on it).
                // Centring the full-width picture on the canvas hid ~5% under the bar.
                let room = max(1, systemY - pictureAnchor)
                let fittedH = min(w / aspect, room)
                let fittedW = fittedH * aspect
                // Rest it on the bar so the free space goes above, not below.
                pictureY = max(pictureAnchor, systemY - fittedH)
                verticalRect = .init(
                    x: (w - fittedW) / 2, y: pictureY, width: fittedW, height: fittedH)
            } else if pictureH > h || pictureH > floor - ceiling {
                // When chrome cannot fit around the picture, keep the picture
                // on the canvas midline instead of using an inverted interval.
                pictureY = (h - pictureH) / 2
            } else {
                // Canvas mid-line, clamped only so the well clears the status
                // row and the camera-value / system strip.
                let ideal = (h - pictureH) / 2
                pictureY = max(ceiling, min(ideal, floor - pictureH))
            }
            picture =
                verticalRect
                ?? .init(x: (w - pictureW) / 2, y: pictureY, width: pictureW, height: pictureH)
            let cy = systemY + systemH / 2
            lock = .init(x: edge, y: cy - button / 2, width: button, height: button)
            display = .init(x: edge + button + 8, y: lock.y, width: button, height: button)
            record = .init(x: (w - rec) / 2, y: cy - rec / 2, width: rec, height: rec)
            // Same order as landscape: Media sits next to Record, Settings outside it.
            settings = .init(x: w - edge - button, y: lock.y, width: button, height: button)
            media = .init(
                x: settings.x - button - Self.settingsMediaGap, y: lock.y, width: button, height: button)
            let cornerTop = max(0, headerSafeTop - 24)
            let gaugeTop = (tablet ? 82 : max(4, cornerTop - 16)) + controlInset
            // Phone: the two battery pills trail the Dynamic Island (the link pill
            // sits left of it with storage). Tablet: all three stacked.
            gauges = .init(
                x: tablet ? edge : w - edge - 122, y: gaugeTop,
                width: tablet ? 64 : 122, height: tablet ? 76 : 22)
            telemetry = tablet ? gauges : .init(
                x: w - headerTrailing - 122, y: gaugeTop + 13 - headerLift, width: 122, height: 22)
            // Portrait tools belong to the lower control area. Picture crop,
            // aspect and FIT/FILL must not move their touch targets.
            assists = .init(
                x: edge, y: floor - 16 - (button + 35),
                width: button + 8, height: button + 35)
            stick = .init(
                x: w - 16 - stickSide,
                y: floor - 16 - stickSide, width: stickSide, height: stickSide)
            zoom = .init(x: stick.x, y: stick.y - 44, width: 44, height: 36)
            gimbal = .init(x: stick.maxX - 36, y: zoom.y, width: 36, height: 36)
            headTrack = Self.headTrack(stick: stick, zoom: zoom)
            aspectToggle = .init(
                x: w / 2 - 24, y: floor - 56, width: 48, height: 48)
        } else {
            fillsPicture = false
            // The physical cutout is smaller than the full safe inset. The
            // picture stays centred across either landscape orientation.
            let cut = desktop ? 0 : max(0, max(safeArea.leading, safeArea.trailing) - 14)
            // Desktop centres the picture in the window below the status row.
            let frame = Self.landscapeFrame(
                width: w, height: h - desktopBand, cut: cut, aspect: Self.frameAspect,
                top: desktop ? desktopBand : nil)
            // A picture taller than the frame (a 3:2 or 4:3 still) scales down inside the video's
            // 16:9 frame instead of growing taller: on a tablet the video's bars stay top and
            // bottom and the still is pillarboxed. A wider picture still spans the usable width.
            picture =
                aspect < Self.frameAspect
                ? frame.fitting(aspect: aspect)
                : Self.landscapeFrame(
                    width: w, height: h - desktopBand, cut: cut, aspect: aspect, top: desktop ? desktopBand : nil)
            // Where the frame leaves bars above and below (a tablet), the status row sits on the
            // top bar as in video, so a still keeps it where video has it. Where the frame runs
            // the full height (a phone), the status row stays on the picture itself.
            let anchor = aspect < Self.frameAspect && frame.height < h - 0.5 ? frame : picture
            system = .init()
            let bottom = hasHome ? 16.0 : 12.0
            record = .init(x: w - 10 - rec, y: h - bottom - rec, width: rec, height: rec)
            // On the cutout edge DISP occupies the remaining band above REC.
            // The trailing rail retains its horizontal center across rotation.
            let cutoutHeight = safeArea.trailing >= 55 ? 112.0 : 124.0
            let availableDisplayHeight =
                safeArea.trailing > 0 && !tablet
                ? record.y - 8 - (h + cutoutHeight) / 2 - 4 : button
            let dispH = max(36, min(button, availableDisplayHeight))
            display = .init(
                x: record.midX - button / 2, y: record.y - 8 - dispH, width: button, height: dispH)
            let hasCutout = max(safeArea.leading, safeArea.trailing) > 0
            // Physical phone corners clip controls authored flush to the edge.
            // Move their cluster down without applying iPad window exclusions
            // or shifting the picture, status actions or bottom camera values.
            let cornerClearance = hasCutout && !tablet ? h * 0.025 : 0
            let cornerTop =
                (tablet ? 12.0 : (hasCutout ? 8.0 : 52.0)) + controlInset + cornerClearance
            let deviceSettings = MonitorRect(
                x: tablet ? w - 14 - button * 2 - Self.settingsMediaGap : record.midX - button / 2,
                y: cornerTop, width: button, height: button)
            let deviceLock = MonitorRect(x: 18, y: cornerTop, width: button, height: button)
            settings = desktop ? .init() : deviceSettings
            media =
                desktop
                ? .init()
                : .init(
                    x: tablet ? deviceSettings.maxX + Self.settingsMediaGap : deviceSettings.x,
                    y: tablet ? cornerTop : deviceSettings.maxY + Self.settingsMediaGap, width: button,
                    height: button)
            lock = desktop ? .init() : deviceLock
            gauges =
                desktop
                ? .init()
                : .init(
                    x: 18, y: deviceLock.maxY + Self.landscapeGaugeGap(tablet: tablet),
                    width: tablet ? 64 : 58, height: tablet ? 76 : 68)
            telemetry = gauges
            // Keep the full 44pt touch target inside the screen. A 35pt band
            // centred at 21.5pt put its accessibility bounds above the window,
            // causing automatic hit-point selection to miss the top buttons.
            status =
                desktop
                ? .init(x: 0, y: titleBar, width: w, height: Self.desktopStatusRowHeight)
                : .init(
                    x: max(77, anchor.x + 12), y: (tablet ? 4 : 0) + controlInset,
                    width: deviceSettings.x - max(77, anchor.x + 12) - 12, height: tablet ? 46 : 44)
            let side = 14 + rec + 28
            let valuesH = showsValues ? 43.0 : 0
            let bottomPad = Self.landscapeBottomClearance(safeBottom: safeArea.bottom)
            let valuesY = h - bottomPad - valuesH
            values = .init(
                x: side, y: valuesY + 4,
                width: w - side * 2, height: valuesH)
            floor = valuesY - 8
            let assistHeight =
                button * 2 + MonitorAssistPaletteLayout.padding * 2
                + MonitorAssistPaletteLayout.spacing
            assists = .init(
                x: 18, y: h - bottomPad - assistHeight,
                width: button + MonitorAssistPaletteLayout.horizontalInsets, height: assistHeight)
            stick = .init(
                x: w - max(16 + rec + 12, safeArea.trailing + 6) - stickSide,
                y: floor - stickSide, width: stickSide, height: stickSide)
            zoom = .init(x: stick.x, y: stick.y - 44, width: 44, height: 36)
            gimbal = .init(x: stick.maxX - 36, y: zoom.y, width: 36, height: 36)
            headTrack = Self.headTrack(stick: stick, zoom: zoom)
            aspectToggle = .init()
        }
        take =
            desktop
            ? .init(x: picture.x, y: picture.y, width: picture.width, height: min(Self.takeBandHeight, picture.height))
            : .init()
        focusReset = .init(
            x: portrait ? max(safeArea.leading + 8, assists.x) : max(safeArea.leading + 8, stick.x - 50),
            y: portrait ? assists.y - 48 : stick.maxY - 40, width: 40, height: 40)
    }

    /// The landscape feed frame's shape: the 16:9 region a video picture fills. A taller picture
    /// fits inside it; chrome is laid out around it. Mirrors Kotlin `MonitorLayoutPolicy.FRAME_ASPECT`.
    static let frameAspect = 16.0 / 9.0

    /// The largest rect of `aspect` centred in a landscape viewport, its width clear of the
    /// cutout band `cut` on both long edges.
    /// `top` is where the viewport starts (the desktop status row's bottom): the rect is centred in
    /// the `height` below it, so the bars above and below the picture are equal.
    static func landscapeFrame(
        width: Double, height: Double, cut: Double, aspect: Double, top: Double? = nil
    ) -> MonitorRect {
        let imageW = min(width - 2 * cut, height * aspect)
        let imageH = imageW / aspect
        return MonitorRect(
            x: (width - imageW) / 2, y: (top ?? 0) + (height - imageH) / 2, width: imageW, height: imageH)
    }

    /// How far the floating scope panels keep from each viewport edge: the safe area on every
    /// side and, in portrait, the system band below the camera values. Fit and fill share it, so
    /// scopes float in both. A panel reaches the trailing edge as it reaches the leading one; the
    /// side rail draws above it and keeps its touches (owner hardware pass 2026-10-30: clearing
    /// the paired tablet Settings and Media keys stopped panels about 140 pt short of the edge).
    /// Mirrors Kotlin `monitorOperatorLiveLayout` and `monitorOperatorFieldLayout` placement.
    public func scopeClearance(safeArea: MonitorSafeArea) -> MonitorSafeArea {
        MonitorSafeArea(
            top: max(0, contentSafeArea(safeArea).top), leading: max(0, safeArea.leading),
            bottom: portrait ? max(0, viewport.height - system.y) : 0,
            trailing: max(0, safeArea.trailing))
    }

    /// The chrome rects a floating scope never covers, for the parts the surface shows now;
    /// `MonitorScopeChromeAvoidance` moves a panel off each one, so scopes reach the edges only
    /// where no control stands. The status row (format, recording and timecode), the gauges, the
    /// rail keys, the camera values, the assist palette as it rests collapsed (an expanded palette
    /// draws over panels as it draws over the values), the motion cluster, the recenter key and
    /// the portrait fit/fill toggle. Fit and fill share it (owner hardware pass 2026-10-30, iPad
    /// Pro 11-inch). Mirrors Kotlin `MonitorFieldLayout.scopeObstacles`.
    public func scopeObstacles(_ shown: MonitorScopeChrome, motionCluster: Bool = false) -> [MonitorRect] {
        let parts: [(MonitorScopeChrome, [MonitorRect])] = [
            (.status, [status, take]), (.telemetry, [telemetry]), (.lock, [lock]),
            (.settings, [settings]), (.media, [media]), (.record, [record]),
            (.display, [display]), (.values, [values]), (.tools, [assists]),
            (.motion, motionCluster ? [stick, zoom, gimbal, headTrack] : []),
            (.focusReset, [focusReset(motionCluster: motionCluster)]),
            (.aspectToggle, portrait ? [aspectToggle] : []),
        ]
        return parts.filter { shown.contains($0.0) }.flatMap(\.1)
            .filter { $0.width > 0 && $0.height > 0 }
    }

    /// The safe area popups, sheets and scopes lay out in. A device keeps the window's own; a
    /// desktop window's top is the status row's bottom, so nothing lands on the row or under the
    /// title bar.
    public func contentSafeArea(_ safeArea: MonitorSafeArea) -> MonitorSafeArea {
        guard chrome == .desktop else { return safeArea }
        var content = safeArea
        content.top = max(safeArea.top, status.maxY)
        return content
    }

    /// Landscape camera values sit above the home indicator instead of overlapping it.
    public static func landscapeBottomClearance(safeBottom: Double) -> Double {
        safeBottom > 0 ? max(safeBottom, 14) + 10 : 8
    }

    /// AE unlock capsule, 1.5× the Recenter key wide. Landscape: beside Recenter,
    /// toward the picture centre. Portrait: mirrored to the left, just right of
    /// the View Assist column on Recenter's baseline, so it clears Fit/Fill (centred)
    /// and the joystick cluster at any width or joystick size.
    public static func aeUnlock(
        focusReset reset: MonitorRect, leadingColumnMaxX: Double, pictureMidX: Double,
        portrait: Bool
    ) -> MonitorRect {
        let width = reset.height * 1.5
        let x =
            portrait
            ? leadingColumnMaxX + 8
            : reset.midX < pictureMidX ? reset.maxX + 8 : reset.x - 8 - width
        return MonitorRect(x: x, y: reset.y, width: width, height: reset.height)
    }

    public var aeUnlock: MonitorRect { aeUnlock(motionCluster: true) }

    /// The recenter key for a camera with or without a motion cluster (gimbal stick and zoom
    /// chip). With one, `focusReset` keeps the key beside the cluster. Without one nothing takes
    /// the feed's trailing bottom corner, so the key moves into it: just inside the picture,
    /// above the camera values and clear of the rail (owner request, hardware pass 2026-10-30).
    /// Mirrors Kotlin `MonitorFieldLayout.focusReset(motionCluster)`.
    public func focusReset(motionCluster: Bool) -> MonitorRect {
        guard !motionCluster else { return focusReset }
        let inset = 8.0
        let right = min(picture.maxX - inset, stick.maxX)
        let bottom = min(picture.maxY - inset, stick.maxY)
        return MonitorRect(
            x: right - focusReset.width, y: bottom - focusReset.height,
            width: focusReset.width, height: focusReset.height)
    }

    /// The AE unlock capsule beside the recenter key `focusReset(motionCluster:)` places. In the
    /// corner it sits on the key's centre side in either orientation: with no joystick to clear,
    /// portrait needs no mirrored placement.
    public func aeUnlock(motionCluster: Bool) -> MonitorRect {
        Self.aeUnlock(
            focusReset: focusReset(motionCluster: motionCluster), leadingColumnMaxX: assists.maxX,
            pictureMidX: picture.midX, portrait: portrait && motionCluster)
    }

    /// The widest an app's own status badge may draw.
    public static let appBadgeWidth = 200.0
    /// Clearance an app status badge keeps from the status row and from reserved chrome.
    public static let appBadgeGap = 8.0

    /// An app's own status badge (a capture health pill): one touch-target row under the status
    /// row, starting at its leading edge and moved past each reserved rect it would touch, so a
    /// tap on the badge never lands on the lock or a gauge. Never wider than the status row.
    /// Mirrors Kotlin `MonitorLayoutPolicy.appBadge`.
    public static func appBadge(status: MonitorRect, reserved: [MonitorRect]) -> MonitorRect {
        let y = status.maxY + appBadgeGap
        var x = status.x
        for rect in reserved.sorted(by: { $0.x < $1.x }) {
            let touchesRow =
                rect.y < y + minimumTapTarget + appBadgeGap && y - appBadgeGap < rect.maxY
            let touchesColumn =
                rect.x - appBadgeGap < x + appBadgeWidth && x < rect.maxX + appBadgeGap
            if touchesRow && touchesColumn { x = rect.maxX + appBadgeGap }
        }
        return MonitorRect(
            x: x, y: y, width: max(0, min(appBadgeWidth, status.maxX - x)), height: minimumTapTarget)
    }

    /// The app status badge slot, clear of the lock, the gauges and the status row in either
    /// orientation. The badge's touch target is this rect; its drawn pill centres in it.
    public var appBadge: MonitorRect {
        Self.appBadge(status: status, reserved: [lock, gauges, telemetry])
    }

    /// 44 pt compass above the zoom row, trailing-aligned with the stick.
    public static func headTrack(stick: MonitorRect, zoom: MonitorRect) -> MonitorRect {
        MonitorRect(x: stick.maxX - 44, y: zoom.y - 8 - 44, width: 44, height: 44)
    }
}

/// A part of the live chrome a floating scope keeps clear of (`FieldMonitorLayout.scopeObstacles`).
/// The surface names the parts it shows. Mirrors Kotlin `MonitorScopeChrome`.
public struct MonitorScopeChrome: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// The status row: format, recording, timecode and storage.
    public static let status = Self(rawValue: 1 << 0)
    /// The link and battery gauges.
    public static let telemetry = Self(rawValue: 1 << 1)
    public static let lock = Self(rawValue: 1 << 2)
    public static let settings = Self(rawValue: 1 << 3)
    public static let media = Self(rawValue: 1 << 4)
    public static let record = Self(rawValue: 1 << 5)
    /// DISP.
    public static let display = Self(rawValue: 1 << 6)
    /// The camera values.
    public static let values = Self(rawValue: 1 << 7)
    /// The assist palette, collapsed.
    public static let tools = Self(rawValue: 1 << 8)
    /// The gimbal stick, zoom chip, gimbal key and head lock.
    public static let motion = Self(rawValue: 1 << 9)
    public static let focusReset = Self(rawValue: 1 << 10)
    /// The portrait fit/fill toggle.
    public static let aspectToggle = Self(rawValue: 1 << 11)
    public static let all: Self = [
        .status, .telemetry, .lock, .settings, .media, .record, .display, .values, .tools,
        .motion, .focusReset, .aspectToggle,
    ]
}
