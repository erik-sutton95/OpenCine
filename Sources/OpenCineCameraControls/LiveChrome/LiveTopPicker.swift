#if os(iOS)
    import MonitorUI
    import SwiftUI

    /// The status row's format and colour pickers.
    public enum LiveTopMenu: Equatable, Sendable {
        case recFormat
        case color
    }

    public struct LiveTopPickerFramesKey: PreferenceKey {
        public static var defaultValue: [LiveTopMenu: CGRect] { [:] }
        public static func reduce(
            value: inout [LiveTopMenu: CGRect], nextValue: () -> [LiveTopMenu: CGRect]
        ) {
            value.merge(nextValue(), uniquingKeysWith: { $1 })
        }
    }

    /// Hold a numeric FPS string until it moves by `step` so hundredths do not
    /// tick the chip. Non-numeric labels (LINK / FAIL / RECOV / dash) always win.
    public enum LiveChromeReadout {
        public static func holdFPS(_ incoming: String, displayed: String, step: Double = 0.4)
            -> String
        {
            guard let next = Double(incoming), let current = Double(displayed) else {
                return incoming
            }
            return abs(next - current) >= step ? incoming : displayed
        }
    }

    /// The status row's picker: backdrop tap, slide-down from above the cell.
    public struct LiveTopSheetHost<Host: CaptureSheetHost>: View {
        @Binding var menu: LiveTopMenu?
        var frames: [LiveTopMenu: CGRect]
        var viewport: CGSize
        var topDeck: CGRect
        var safeArea: EdgeInsets
        var floorY: CGFloat?

        @State private var revealed = false
        @State private var panelHeight: CGFloat = 280

        private static var revealCurve: Animation {
            Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.20)
        }

        public init(
            menu: Binding<LiveTopMenu?>, frames: [LiveTopMenu: CGRect], viewport: CGSize,
            topDeck: CGRect, safeArea: EdgeInsets = EdgeInsets(), floorY: CGFloat? = nil
        ) {
            _menu = menu
            self.frames = frames
            self.viewport = viewport
            self.topDeck = topDeck
            self.safeArea = safeArea
            self.floorY = floorY
        }

        public var body: some View {
            let cell =
                frames[menu ?? .recFormat]
                ?? CGRect(x: topDeck.midX - 40, y: topDeck.minY, width: 80, height: topDeck.height)
            let place = LivePopupPlacement.topPicker(
                cell: cell,
                panelHeight: panelHeight,
                viewport: viewport,
                safeArea: safeArea,
                floorY: floorY
            )
            let slide = place.y + panelHeight + 40

            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .named(LiveCanvasSpace.name)) { location in
                        handleBackdrop(at: location)
                    }

                CaptureSheetPanel<Host>(
                    sheet: menu == .color ? .color : .resolution
                ) {
                    menu = nil
                }
                .id(menu)
                .transition(.opacity)
                .frame(width: place.width)
                .background(panelHeightReader)
                .opacity(revealed ? 1 : 0)
                .offset(x: place.x, y: place.y + (revealed ? 0 : -slide))
            }
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
            .onAppear { scheduleReveal() }
        }

        private var panelHeightReader: some View {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { panelHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, height in
                        panelHeight = height
                    }
            }
        }

        private func scheduleReveal() {
            DispatchQueue.main.async {
                withAnimation(Self.revealCurve) { revealed = true }
            }
        }

        private func handleBackdrop(at location: CGPoint) {
            if let hit = frames.first(where: {
                $0.value.insetBy(dx: -10, dy: -8).contains(location)
            }) {
                if hit.key == menu {
                    menu = nil
                } else {
                    withAnimation(.easeInOut(duration: 0.14)) { menu = hit.key }
                }
                return
            }
            menu = nil
        }
    }
#endif
