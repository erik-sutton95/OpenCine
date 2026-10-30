import Foundation

/// What a camera value is for. Exposure values (program, ISO, shutter, aperture, metering) are
/// ridden shot to shot; setup values (drive, focus mode, white balance, picture profile) say how
/// the camera captures and renders the picture. A value nobody grouped is exposure.
/// Mirrors Kotlin `MonitorCaptureReadoutGroup`.
public enum MonitorCaptureReadoutGroup: String, CaseIterable, Sendable {
    case exposure, setup
}

/// The trailing corner of the landscape status row. While video runs it holds the recording
/// readout and the clock. A photo row has neither, so the camera's setup values move up into it
/// and the strip along the bottom keeps exposure: nine photo values in one landscape row clipped
/// their captions on a compact phone (hardware pass 2026-10-30). Portrait keeps every value in the
/// strip's grid, which wraps a row instead of clipping, and its status row's trailing slot
/// already holds the format readouts. Mirrors Kotlin `MonitorStatusCorner`.
public enum MonitorStatusCorner {
    /// Space between two corner tiles.
    public static let tileSpacing = 12.0
    /// The least space kept between the leading status readouts and the corner.
    public static let leadingGap = 16.0

    /// Whether the corner takes the setup values: a landscape photo row that shows both the
    /// status row and the camera values.
    public static func holdsSetup(
        photo: Bool, portrait: Bool, statusShown: Bool, valuesShown: Bool
    ) -> Bool {
        photo && !portrait && statusShown && valuesShown
    }

    /// The values the strip and the corner show, each in the source's order. Without a corner
    /// the strip shows them all.
    public static func split<Value>(
        _ values: [Value], holdsSetup: Bool, group: (Value) -> MonitorCaptureReadoutGroup
    ) -> (strip: [Value], corner: [Value]) {
        guard holdsSetup else { return (values, []) }
        return (values.filter { group($0) != .setup }, values.filter { group($0) == .setup })
    }

    /// Tile widths for a corner `available` wide. Tiles keep their natural widths when those fit.
    /// Otherwise every tile gives up the same share of its width above its floor (its whole
    /// caption), and no tile goes below its floor: a caption is never cut. When even the floors
    /// do not fit, the corner keeps its floors and the leading readouts make room.
    public static func widths(
        natural: [Double], floors: [Double], available: Double, spacing: Double = tileSpacing
    ) -> [Double] {
        guard natural.count == floors.count, !natural.isEmpty else { return natural }
        let floors = zip(natural, floors).map { min($0, max(0, $1)) }
        let gaps = spacing * Double(natural.count - 1)
        let room = max(0, available - gaps)
        let total = natural.reduce(0, +)
        guard total > room else { return natural }
        let floorTotal = floors.reduce(0, +)
        let slack = total - floorTotal
        guard slack > 0, room > floorTotal else { return floors }
        let keep = (room - floorTotal) / slack
        return zip(natural, floors).map { $1 + ($0 - $1) * keep }
    }

    /// The corner's width for the tile widths `widths(...)` returns.
    public static func width(of tiles: [Double], spacing: Double = tileSpacing) -> Double {
        tiles.reduce(0, +) + spacing * Double(max(0, tiles.count - 1))
    }
}
