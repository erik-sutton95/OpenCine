#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineCameraVocabulary
    import SwiftUI
    import UIKit

    /// The reference monitor's zoom gesture tail and Android's `completeDrag`.
    /// Down: clean (DISP 2). Up: live (DISP 1). `nil` if too short or not vertical.
    public enum LiveDispSwipe {
        /// Same +8 pt axis margin as the completed swipe, without the 44 pt floor.
        public static func isVerticalDominant(_ translation: CGSize) -> Bool {
            abs(translation.height) > abs(translation.width) + 8
        }

        public static func wantsClean(translation: CGSize) -> Bool? {
            let dy = translation.height
            guard isVerticalDominant(translation), abs(dy) > 44 else { return nil }
            return dy > 0
        }
    }

    /// Swipe = DISP. Slight long-press then drag = tracking box.
    /// Short press = tap focus, or ActiveTrack if the tap is on the AF-C face box.
    public enum LiveFeedFocusGesture {
        public enum Kind: Equatable, Sendable {
            case tap
            case track
            case aeLock
            case dispClean
            case dispLive
        }

        public static let trackMinimum: CGFloat = 24
        /// Short enough to feel like a press, long enough that a swipe never arms.
        public static let trackHoldDuration: TimeInterval = 0.20
        public static let trackHoldSlop: CGFloat = 10
        /// A still press this long releases as AE lock instead of tap focus. On the focus
        /// box it toggles the box lock instead.
        public static let aeLockHoldDuration: TimeInterval = 0.6
        /// Focus box side as a share of the feed's short side (`FocusBoxView`).
        public static let focusBoxSideFraction: CGFloat = 0.14
        /// Room around the focus box that still counts as pressing it.
        public static let focusBoxHitMargin: CGFloat = 14
        public static let focusLockedNote = "Focus box locked. Long-press it to unlock."

        /// Whether `location` (well coordinates) presses the tap-focus box at camera point `focus`.
        public static func hitsFocusBox(
            _ location: CGPoint, focus: CGPoint, in size: CGSize, mirrored: Bool,
            flippedVertically: Bool = false
        ) -> Bool {
            let x = (mirrored ? 1 - focus.x : focus.x) * size.width
            let y = (flippedVertically ? 1 - focus.y : focus.y) * size.height
            let reach = min(size.width, size.height) * focusBoxSideFraction / 2 + focusBoxHitMargin
            return abs(location.x - x) <= reach && abs(location.y - y) <= reach
        }

        public static func classify(
            translation: CGSize, pinched: Bool = false, armed: Bool = false,
            aeLockHeld: Bool = false
        ) -> Kind? {
            if pinched { return nil }
            let distance = hypot(translation.width, translation.height)
            if armed {
                if distance >= trackMinimum { return .track }
                return aeLockHeld ? .aeLock : .tap
            }
            if let clean = LiveDispSwipe.wantsClean(translation: translation) {
                return clean ? .dispClean : .dispLive
            }
            if distance >= trackMinimum { return nil }
            return .tap
        }

        public static func cameraPoint(
            _ location: CGPoint, in size: CGSize, mirrored: Bool, flippedVertically: Bool = false
        ) -> (x: Double, y: Double) {
            let nx = min(max(Double(location.x / max(size.width, 1)), 0), 1)
            let ny = min(max(Double(location.y / max(size.height, 1)), 0), 1)
            return (mirrored ? 1 - nx : nx, flippedVertically ? 1 - ny : ny)
        }

        public static func cameraBox(
            from: CGPoint, to: CGPoint, in size: CGSize, mirrored: Bool,
            flippedVertically: Bool = false
        ) -> TrackingBox {
            let a = cameraPoint(
                from, in: size, mirrored: mirrored, flippedVertically: flippedVertically)
            let b = cameraPoint(
                to, in: size, mirrored: mirrored, flippedVertically: flippedVertically)
            return TrackingBox.normalized(fromX: a.x, fromY: a.y, toX: b.x, toY: b.y)
        }
    }

    /// Feed-sized pinch + DISP swipe well. Lives in the chrome stack **under** the
    /// zoom chip and scope panels, **above** `VideoView`. Do not hang these
    /// gestures on the screen `GeometryReader`: the UIKit feed plus WAVE/HISTO/rails
    /// eat that pinch, and a screen drag would steal record / assist hits.
    public struct FeedGestureWell<Host: LiveChromeHost>: View {
        var feed: CGRect
        var chip: CGRect
        var stick: CGRect
        var gimbalButton: CGRect
        var reset: CGRect
        var aeUnlock: CGRect
        var cancel: CGRect
        var calibrate: CGRect
        var enabled: Bool
        @State private var draftStart: CGPoint?
        @State private var draftEnd: CGPoint?

        public init(
            feed: CGRect, chip: CGRect, stick: CGRect = .zero, gimbalButton: CGRect = .zero,
            reset: CGRect = .zero, aeUnlock: CGRect = .zero, cancel: CGRect = .zero,
            calibrate: CGRect = .zero, enabled: Bool
        ) {
            self.feed = feed
            self.chip = chip
            self.stick = stick
            self.gimbalButton = gimbalButton
            self.reset = reset
            self.aeUnlock = aeUnlock
            self.cancel = cancel
            self.calibrate = calibrate
            self.enabled = enabled
        }

        public var body: some View {
            let chipInFeed = chip.offsetBy(dx: -feed.minX, dy: -feed.minY)
            let stickInFeed = stick.offsetBy(dx: -feed.minX, dy: -feed.minY)
            let gimbalInFeed = gimbalButton.offsetBy(dx: -feed.minX, dy: -feed.minY)
            let resetInFeed = reset.offsetBy(dx: -feed.minX, dy: -feed.minY)
            let aeUnlockInFeed = aeUnlock.offsetBy(dx: -feed.minX, dy: -feed.minY)
            let cancelInFeed = cancel.offsetBy(dx: -feed.minX, dy: -feed.minY)
            let calibrateInFeed = calibrate.offsetBy(dx: -feed.minX, dy: -feed.minY)
            ZStack {
                Color.white.opacity(0.001)
                if let start = draftStart, let end = draftEnd {
                    draftBox(from: start, to: end)
                }
            }
            .frame(width: feed.width, height: feed.height)
            .contentShape(
                .interaction,
                LiveZoomPinchHitShape(holes: [
                    chipInFeed, stickInFeed, gimbalInFeed, resetInFeed, aeUnlockInFeed,
                    cancelInFeed,
                    calibrateInFeed,
                ]),
                eoFill: true
            )
            .modifier(
                FeedGestureModifier<Host>(
                    enabled: enabled,
                    feedSize: CGSize(width: feed.width, height: feed.height),
                    draftStart: $draftStart,
                    draftEnd: $draftEnd
                )
            )
            .position(x: feed.midX, y: feed.midY)
            .allowsHitTesting(enabled)
            .accessibilityHidden(true)
        }

        private func draftBox(from start: CGPoint, to end: CGPoint) -> some View {
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            return RoundedRectangle(
                cornerRadius: MonitorTrackingGeometry.cornerRadius(for: rect), style: .continuous
            )
            .stroke(Host.Palette.text.opacity(0.88), lineWidth: 1.5)
            .shadow(color: .black.opacity(0.6), radius: 1)
            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
        }
    }

    /// Feed pinch well with holes over the zoom chip and gimbal stick.
    private struct LiveZoomPinchHitShape: Shape {
        var holes: [CGRect]

        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.addRect(rect)
            for hole in holes {
                let cut = hole.insetBy(dx: -2, dy: -2).intersection(rect)
                if !cut.isEmpty { path.addRect(cut) }
            }
            return path
        }
    }

    struct FeedGestureModifier<Host: LiveChromeHost>: ViewModifier {
        @Environment(Host.self) private var host
        var enabled: Bool
        var feedSize: CGSize
        @Binding var draftStart: CGPoint?
        @Binding var draftEnd: CGPoint?
        @State private var pinchUsed = false
        @State private var detentTick = 0.0
        @State private var focusTick = 0
        @State private var trackArmed = false
        @State private var aeLockHeld = false
        @State private var holdStarted = false
        @State private var holdTask: Task<Void, Never>?
        @State private var lastTranslation: CGSize = .zero
        /// The press started on the tap-focus box, so a long hold toggles its lock.
        @State private var pressOnFocusBox = false
        @State private var focusLockToggled = false

        func body(content: Content) -> some View {
            content
                .gesture(zoomGestures, including: enabled ? .gesture : .none)
                .sensoryFeedback(trigger: detentTick) { _, _ in host.hapticsEnabled ? .impact(weight: .medium) : nil }
                .sensoryFeedback(trigger: focusTick) { _, _ in host.hapticsEnabled ? .impact(weight: .light) : nil }
                .onChange(of: aeLockHeld) { _, held in if held, host.hapticsEnabled { Self.playAELockHaptic() } }
        }

        /// Two full-strength heavy taps: a single heavy impact read too soft for a lock.
        @MainActor private static func playAELockHaptic() {
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.impactOccurred(intensity: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
                generator.impactOccurred(intensity: 1)
            }
        }

        /// One drag beside pinch so they coexist; the host's pinch paces the camera.
        private var zoomGestures: some Gesture {
            pinch.simultaneously(with: feedDrag)
        }

        private var pinch: some Gesture {
            MagnifyGesture()
                .onChanged { value in
                    guard enabled else { return }
                    if !pinchUsed { host.zoomPinchWillBegin() }
                    pinchUsed = true
                    cancelTrackHold()
                    draftStart = nil
                    draftEnd = nil
                    host.updateZoomPinch(magnification: Double(value.magnification))
                    let preview = host.zoomPinchPreview ?? 0
                    if CamFov.isJumpStop(preview, stops: host.zoomStops) {
                        if detentTick != preview { detentTick = preview }
                    } else if detentTick != 0 {
                        detentTick = 0
                    }
                }
                .onEnded { _ in
                    host.endZoomPinch()
                    detentTick = 0
                    DispatchQueue.main.async { pinchUsed = false }
                }
        }

        private var feedDrag: some Gesture {
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard enabled, !pinchUsed else { return }
                    lastTranslation = value.translation
                    if !holdStarted {
                        holdStarted = true
                        pressOnFocusBox = pressesFocusBox(value.startLocation)
                        beginTrackHold()
                    }
                    let slop = hypot(value.translation.width, value.translation.height)
                    if !trackArmed, slop > LiveFeedFocusGesture.trackHoldSlop {
                        holdTask?.cancel()
                        holdTask = nil
                    }
                    guard trackArmed else {
                        draftStart = nil
                        draftEnd = nil
                        return
                    }
                    draftStart = value.startLocation
                    draftEnd = value.location
                }
                .onEnded { value in
                    let armed = trackArmed
                    let aeLock = aeLockHeld
                    let toggledLock = focusLockToggled
                    cancelTrackHold()
                    if toggledLock { return }
                    draftStart = nil
                    draftEnd = nil
                    guard enabled else { return }
                    guard
                        let kind = LiveFeedFocusGesture.classify(
                            translation: value.translation, pinched: pinchUsed, armed: armed,
                            aeLockHeld: aeLock)
                    else { return }
                    switch kind {
                    case .dispClean:
                        host.setDisplayMode(clean: true)
                    case .dispLive:
                        host.setDisplayMode(clean: false)
                    case .tap, .aeLock:
                        if kind == .aeLock, host.lockAutoExposure() { return }
                        guard !host.focusBoxLocked else {
                            host.showControlNote(LiveFeedFocusGesture.focusLockedNote)
                            return
                        }
                        let point = LiveFeedFocusGesture.cameraPoint(
                            value.location, in: feedSize, mirrored: host.livePictureViewFlip,
                            flippedVertically: host.assist.flipsVertically)
                        host.handleFeedTap(at: CGPoint(x: point.x, y: point.y))
                        focusTick += 1
                    case .track:
                        host.startTracking(
                            LiveFeedFocusGesture.cameraBox(
                                from: value.startLocation,
                                to: value.location,
                                in: feedSize,
                                mirrored: host.livePictureViewFlip,
                                flippedVertically: host.assist.flipsVertically
                            )
                        )
                        focusTick += 1
                    }
                }
        }

        private func beginTrackHold() {
            holdTask?.cancel()
            holdTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(LiveFeedFocusGesture.trackHoldDuration))
                guard !Task.isCancelled, enabled, !pinchUsed else { return }
                let slop = hypot(lastTranslation.width, lastTranslation.height)
                guard slop <= LiveFeedFocusGesture.trackHoldSlop else { return }
                // Arming is silent (Android parity): a still press only buzzes when AE can lock.
                trackArmed = true
                try? await Task.sleep(
                    for: .seconds(
                        LiveFeedFocusGesture.aeLockHoldDuration
                            - LiveFeedFocusGesture.trackHoldDuration))
                guard !Task.isCancelled, !pinchUsed,
                    hypot(lastTranslation.width, lastTranslation.height)
                        <= LiveFeedFocusGesture.trackHoldSlop
                else { return }
                if pressOnFocusBox {
                    host.focusBoxLocked.toggle()
                    focusLockToggled = true
                    Self.playAELockHaptic()
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: host.focusBoxLocked ? "Focus box locked" : "Focus box unlocked")
                    return
                }
                guard host.canLockAutoExposure else { return }
                aeLockHeld = true
            }
        }

        private func cancelTrackHold() {
            holdTask?.cancel()
            holdTask = nil
            holdStarted = false
            trackArmed = false
            aeLockHeld = false
            lastTranslation = .zero
            pressOnFocusBox = false
            focusLockToggled = false
        }

        private func pressesFocusBox(_ location: CGPoint) -> Bool {
            guard let focus = host.tapFocusPoint else { return false }
            return LiveFeedFocusGesture.hitsFocusBox(
                location, focus: focus, in: feedSize,
                mirrored: host.livePictureViewFlip, flippedVertically: host.assist.flipsVertically)
        }
    }

    /// Ignore sub-tenth `cam_fov` jitter on the chip unless the operator is pinching.
    public enum LiveZoomLabelHold {
        public static func shouldReplace(
            held: Double, next: Double, pinching: Bool, epsilon: Double = 0.12
        ) -> Bool {
            if pinching { return true }
            return abs(next - held) >= epsilon
        }
    }

    /// Separate ordinary and extended tap cycles, with the existing hold-to-open dial.
    public struct ZoomChip<Host: LiveChromeHost>: View {
        var onOpenDial: (() -> Void)?
        @Environment(Host.self) private var host
        @Environment(\.interfaceLocked) private var interfaceLocked
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var heldFactor: Double?
        @State private var snapTick = 0

        public init(onOpenDial: (() -> Void)? = nil) {
            self.onOpenDial = onOpenDial
        }

        private var factor: Double { host.zoomFactor }
        private var displayFactor: Double { heldFactor ?? factor }
        /// Unsnapped live / preview so 2.89× (shown 2.9×, still wide) cycles to 3×, not 12×.
        private var cycleFrom: Double { host.zoomCycleOrigin }
        private var title: String {
            CamFov.displayLabel(factor: displayFactor, ceiling: host.zoomCeiling)
        }
        private var opticalStops: [Double] {
            let stops = tapStops.singleTap
            return stops.isEmpty ? [1] : stops
        }
        private var isDigitalCrop: Bool {
            MonitorZoomCaption.isDigital(factor: displayFactor, opticalStops: opticalStops)
        }
        private var tapStops: MonitorZoomTapStops { host.zoomTapStops }
        private var tapGesture: AnyGesture<Bool> {
            guard !tapStops.doubleTap.isEmpty else {
                return AnyGesture(TapGesture().map { false })
            }
            return AnyGesture(
                TapGesture(count: 2).exclusively(before: TapGesture()).map { result in
                    if case .first = result { return true }
                    return false
                })
        }
        /// D-Log2 while rolling: gray like lock, but keep the tap so we can toast.
        private var zoomBlockedWhileRecording: Bool {
            CamFov.zoomNeedsColorHopWhileRecording(
                factor: tapStops.next(from: cycleFrom) ?? cycleFrom,
                current: host.cameraStatus.colorMode,
                isRecording: host.cameraStatus.isRecording)
        }

        private func cycle(extended: Bool = false) {
            guard !interfaceLocked, let next = tapStops.next(from: cycleFrom, extended: extended)
            else {
                return
            }
            snapTick += 1
            host.cycleZoom(to: next)
        }

        public var body: some View {
            KeyframeAnimator(initialValue: Double(1), trigger: snapTick) { progress in
                Text(title)
                    .font(MonitorTheme.font(18, weight: .bold))
                    .foregroundStyle(isDigitalCrop ? MonitorTheme.digitalCrop : Host.Palette.text)
                    .minimumScaleFactor(0.75)
                    .scaleEffect(reduceMotion ? 1 : MonitorMotion.chipPopScale(at: progress))
                    .frame(
                        width: 44,
                        height: 44
                    )
                    .monitorReadoutShadow()
                    .contentShape(Rectangle())
            } keyframes: { _ in
                MoveKeyframe(0)
                LinearKeyframe(1, duration: MonitorMotion.chipPopDuration)
            }
            .gesture(
                LongPressGesture(minimumDuration: 0.38).exclusively(before: tapGesture)
                    .onEnded { gesture in
                        guard !interfaceLocked else { return }
                        switch gesture {
                        case .first: onOpenDial?()
                        case .second(let extended): cycle(extended: extended)
                        }
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { cycle() }
            .accessibilityActions {
                if !tapStops.doubleTap.isEmpty {
                    Button("Extended zoom") { cycle(extended: true) }
                }
                Button("Continuous zoom") { if !interfaceLocked { onOpenDial?() } }
            }
            .opacity(interfaceLocked || zoomBlockedWhileRecording ? 0.4 : 1)
            .allowsHitTesting(!interfaceLocked)
            .disabled(interfaceLocked)
            .accessibilityLabel(
                isDigitalCrop ? "Zoom \(title), digital crop" : "Zoom \(title)"
            )
            .accessibilityHint(
                tapStops.doubleTap.isEmpty
                    ? "Tap cycles camera zoom stops. Hold opens the continuous zoom dial."
                    : "Tap cycles 1 and 3 times. Double tap cycles 6 and 12 times. Hold opens the continuous zoom dial."
            )
            .accessibilityIdentifier("monitor.system.zoom")
            .sensoryFeedback(trigger: snapTick) { _, _ in host.hapticsEnabled ? .impact(weight: .medium) : nil }
            .onAppear { heldFactor = factor }
            .onChange(of: factor) { _, next in
                let pinching = host.zoomPinchPreview != nil
                if let held = heldFactor,
                    !LiveZoomLabelHold.shouldReplace(held: held, next: next, pinching: pinching)
                {
                    return
                }
                heldFactor = next
            }
        }
    }
#endif
