#if os(iOS)
import MonitorPresentation
import SwiftUI

/// Optional camera-coordinate focus operations, admitted by the captured native source adapter.
@MainActor public struct MonitorPictureFocusInteraction {
    public let locked: Bool
    public let current: () -> Bool
    public let tap: (CGPoint) -> Void
    public let toggleLock: () -> Void
    public init(locked: Bool, current: @escaping () -> Bool,
        tap: @escaping (CGPoint) -> Void, toggleLock: @escaping () -> Void) {
        self.locked = locked; self.current = current; self.tap = tap; self.toggleLock = toggleLock
    }
}

/// Picture manipulation and focus-hold presentation over one retained bounded native child.
/// The child receives draw progress; source retirement never starts or stops a camera.
public struct MonitorInteractivePicture<Source: Hashable, Picture: View>: View {
    private let source: Source
    private let size: CGSize
    private let presentationScale: CGSize
    private let enabled: Bool
    private let focus: MonitorPictureFocusInteraction?
    private let swipe: ((MonitorPlaybackChromeSwipe) -> Void)?
    private let picture: (CGFloat) -> Picture
    @State private var zoom: MonitorPlaybackZoom
    @State private var pinch = MonitorEditingSession()
    @State private var pan = MonitorEditingSession()
    @State private var focusHold = MonitorEditingSession()
    @State private var lockProgress: CGFloat = 0
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var anchor: CGPoint?
    @GestureState private var translation = CGSize.zero
    @GestureState private var holding = false
    @GestureState private var pinching = false
    @GestureState private var panning = false

    /// Retains the original initializer for callers with no presentation transform.
    public init(source: Source, size: CGSize, maximumZoom: CGFloat = MonitorPlaybackZoom.maxScale,
        enabled: Bool = true, focus: MonitorPictureFocusInteraction? = nil,
        swipe: ((MonitorPlaybackChromeSwipe) -> Void)? = nil,
        @ViewBuilder picture: @escaping (CGFloat) -> Picture) {
        self.init(source: source, size: size, maximumZoom: maximumZoom, enabled: enabled,
            focus: focus, swipe: swipe, presentationScale: CGSize(width: 1, height: 1),
            picture: picture)
    }

    /// Retires captured gestures when the displayed source changes its transform.
    public init(source: Source, size: CGSize, maximumZoom: CGFloat = MonitorPlaybackZoom.maxScale,
        enabled: Bool = true, focus: MonitorPictureFocusInteraction? = nil,
        swipe: ((MonitorPlaybackChromeSwipe) -> Void)? = nil,
        presentationScale: CGSize,
        @ViewBuilder picture: @escaping (CGFloat) -> Picture) {
        self.source = source; self.size = size; self.enabled = enabled
        self.focus = focus; self.swipe = swipe; self.picture = picture
        self.presentationScale = presentationScale
        _zoom = State(initialValue: MonitorPlaybackZoom(maximumScale: maximumZoom))
    }
    private var transform: MonitorPlaybackZoom {
        zoom.preview(magnification: pinch.isEditing ? magnification : 1,
            anchor: pinch.isEditing ? anchor : nil, translation: pan.isEditing ? translation : .zero, size: size)
    }
    public var body: some View {
        picture(lockProgress)
            .scaleEffect(transform.scale, anchor: .center).offset(transform.offset)
            .frame(width: size.width, height: size.height).clipped().contentShape(Rectangle())
            .simultaneousGesture(zoomGestures)
            .gesture(SpatialTapGesture().onEnded { value in
                guard enabled, let focus, focus.current() else { return }
                focus.tap(transform.sourcePoint(value.location, size: size))
            })
            .simultaneousGesture(LongPressGesture(minimumDuration: 10)
                .updating($holding) { pressed, state, _ in state = pressed })
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.3).onEnded { _ in
                guard enabled, focusHold.isEditing, let focus, focus.current() else { return }
                focus.toggleLock()
            })
            .onChange(of: holding) { _, pressed in
                if pressed {
                    guard enabled, focus != nil, focusHold.begin() else { return }
                    withAnimation(.linear(duration: 0.2).delay(0.1)) { lockProgress = 1 }
                } else {
                    _ = focusHold.end()
                    withAnimation(.easeOut(duration: 0.16)) { lockProgress = 0 }
                }
            }
            .onChange(of: focus?.locked) { _, _ in lockProgress = 0 }
            .onChange(of: source) { _, _ in retire(reset: true) }
            .onChange(of: enabled) { _, active in if !active { retire(reset: false) } }
            .onChange(of: size) { _, _ in retire(reset: false) }
            .onChange(of: presentationScale) { _, _ in retire(reset: false) }
            .onChange(of: pinching) { _, active in if !active, !pinch.isEditing { _ = pinch.end() } }
            .onChange(of: panning) { _, active in if !active, !pan.isEditing { _ = pan.end() } }
            .onDisappear { retire(reset: true) }
    }
    private var zoomGestures: some Gesture {
        let magnify = MagnifyGesture()
            .updating($pinching) { _, state, _ in state = true }
            .updating($magnification) { value, state, _ in state = value.magnification }
            .updating($anchor) { value, state, _ in if state == nil { state = value.startLocation } }
            .onChanged { _ in if enabled { _ = pinch.begin() } }
            .onEnded { value in
                guard pinch.end(), enabled else { return }
                var next = zoom.preview(magnification: value.magnification, anchor: value.startLocation,
                    translation: .zero, size: size)
                next.endPinch(size: size)
                if next.scale == 1 { withAnimation(.spring(duration: 0.25)) { zoom = next } }
                else { zoom = next }
            }
        let drag = DragGesture(minimumDistance: 1)
            .updating($panning) { _, state, _ in state = true }
            .updating($translation) { value, state, _ in if zoom.isZoomed { state = value.translation } }
            .onChanged { _ in if enabled { _ = pan.begin() } }
            .onEnded { value in
                guard pan.end(), enabled else { return }
                if zoom.isZoomed {
                    zoom = zoom.preview(magnification: 1, anchor: nil, translation: value.translation, size: size)
                    zoom.endPan(size: size)
                } else {
                    swipe?(MonitorPlaybackChromeSwipe.classify(dx: Double(value.translation.width), dy: Double(value.translation.height)))
                }
            }
        return magnify.simultaneously(with: drag)
    }
    private func retire(reset: Bool) {
        _ = pinch.cancel(pointerIsActive: pinching)
        _ = pan.cancel(pointerIsActive: panning)
        _ = focusHold.cancel(pointerIsActive: holding)
        lockProgress = 0
        if reset { zoom.reset() } else { zoom.endGesture(size: size) }
    }
}
#endif
