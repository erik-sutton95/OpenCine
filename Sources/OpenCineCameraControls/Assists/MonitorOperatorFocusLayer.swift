import Foundation

/// The focus mark's ink (twin of the Compose `MonitorOperatorFocusInk`): AE lock wins; a camera
/// that reports a focus result shows it confirmed or unconfirmed; otherwise the accent tap box.
public enum MonitorOperatorFocusInk: Equatable, Sendable {
    case accent, aeLock, confirmed, unconfirmed

    public static func of(aeLocked: Bool, focusConfirmed: Bool?) -> MonitorOperatorFocusInk {
        if aeLocked { return .aeLock }
        switch focusConfirmed {
        case true?: return .confirmed
        case false?: return .unconfirmed
        case nil: return .accent
        }
    }
}

#if os(iOS)
    import MonitorUI
    import OpenCineCameraVocabulary
    import SwiftUI

    /// The shared focus layer (twin of the Compose `MonitorOperatorFocusLayer`): tracking brackets
    /// for the current overlay and the dimmed scene faces, the focus mark, and camera-reported AF
    /// areas. `focusArea` gives the mark the size and centre of the camera's AF area;
    /// `otherFocusAreas` (group AF) draw as plain boxes in the confirmed colour; `focusConfirmed`
    /// is the camera's focus result where the body reports one; `focusLockProgress` fills the
    /// mark's outline while the operator holds to lock. Areas are in camera orientation and
    /// normalized; the layer applies the picture's mirror and vertical flip. `overlay` and
    /// `dimmedFaces` are the Compose `TrackingHud` fields.
    public struct MonitorOperatorFocusLayer<Palette: LiveChromePalette>: View {
        private let overlay: FocusOverlay
        private let dimmedFaces: [TrackingBox]
        private let focus: CGPoint?
        private let mirrored: Bool
        private let showTapFocusBox: Bool
        private let aeLocked: Bool
        private let flippedVertically: Bool
        private let focusLocked: Bool
        private let focusArea: TrackingBox?
        private let otherFocusAreas: [TrackingBox]
        private let focusConfirmed: Bool?
        private let focusLockProgress: Double
        private let feed: CGRect

        public init(
            palette: Palette.Type, overlay: FocusOverlay = .focus, dimmedFaces: [TrackingBox] = [],
            focus: CGPoint?, mirrored: Bool, showTapFocusBox: Bool, aeLocked: Bool = false,
            flippedVertically: Bool = false, focusLocked: Bool = false,
            focusArea: TrackingBox? = nil, otherFocusAreas: [TrackingBox] = [],
            focusConfirmed: Bool? = nil, focusLockProgress: Double = 0, feed: CGRect
        ) {
            self.overlay = overlay
            self.dimmedFaces = dimmedFaces
            self.focus = focus
            self.mirrored = mirrored
            self.showTapFocusBox = showTapFocusBox
            self.aeLocked = aeLocked
            self.flippedVertically = flippedVertically
            self.focusLocked = focusLocked
            self.focusArea = focusArea
            self.otherFocusAreas = otherFocusAreas
            self.focusConfirmed = focusConfirmed
            self.focusLockProgress = focusLockProgress
            self.feed = feed
        }

        /// The green of a held subject and of camera-confirmed focus.
        static var confirmed: Color { Color(red: 0.18, green: 0.78, blue: 0.42) }

        private func drawn(_ box: TrackingBox) -> CGRect {
            let shown = box.flipped(horizontal: mirrored, vertical: flippedVertically)
            return CGRect(x: shown.x, y: shown.y, width: shown.width, height: shown.height)
        }

        private func bracket(_ box: TrackingBox, _ color: Color, _ width: CGFloat)
            -> MonitorTrackingBracketValue
        {
            MonitorTrackingBracketValue(normalizedRect: drawn(box), color: color, lineWidth: width)
        }

        public var body: some View {
            var brackets = dimmedFaces.map { bracket($0, Palette.text.opacity(0.20), 1.6) }
            let showFocus: Bool
            switch overlay {
            case .search(let box):
                brackets.append(bracket(box, Palette.text.opacity(0.88), 1.5))
                showFocus = showTapFocusBox
            case .subject(let box):
                brackets.append(bracket(box, Self.confirmed, 2))
                showFocus = false
            case .face(let box):
                brackets.append(bracket(box, Palette.text.opacity(0.92), 1.6))
                showFocus = false
            case .focus:
                showFocus = showTapFocusBox
            }
            let color: Color =
                switch MonitorOperatorFocusInk.of(
                    aeLocked: aeLocked, focusConfirmed: focusConfirmed)
                {
                case .aeLock: Palette.aeLock
                case .confirmed: Self.confirmed
                case .unconfirmed: Palette.text.opacity(0.72)
                case .accent: Palette.accent
                }
            let mark = focus.flatMap { point in
                showFocus
                    ? MonitorFocusMark(
                        point: CGPoint(
                            x: mirrored ? 1 - point.x : point.x,
                            y: flippedVertically ? 1 - point.y : point.y),
                        color: color, aeLocked: aeLocked, focusLocked: focusLocked,
                        area: focusArea.map(drawn), lockProgress: focusLockProgress) : nil
            }
            let areas =
                showFocus
                ? otherFocusAreas.map { box -> MonitorFocusMark in
                    let rect = drawn(box)
                    return MonitorFocusMark(
                        point: CGPoint(x: rect.midX, y: rect.midY), color: Self.confirmed,
                        area: rect)
                } : []
            return MonitorTrackingLayer(brackets: brackets, focus: mark, feed: feed, areas: areas)
        }
    }
#endif
