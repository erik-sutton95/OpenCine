import Foundation
import OpenCineMedia

/// Operator gamepad map (discussion #159). Extended pads only.
///
/// Cross/A records. Circle/B recenters. Square/X is 180. Triangle/Y tracks
/// a face (the discussion left that face free). L1/R1 are zoom-chip jumps.
/// L2/R2 stay analog zoom in the shells. D-pad is ISO (up/down) and shutter
/// (left opens / slower, right closes / faster). `camcap_shutter` is fast-first
/// (1/16000 → 1/4), so open is `steppedDenom(+1)` and close is `−1`.
public enum GamepadOperatorAction: Equatable, Sendable {
    case record
    case recenter
    case flip
    case track
    case zoomChipIn
    case zoomChipOut
    case isoUp
    case isoDown
    case shutterOpen
    case shutterClose
}

public enum GamepadFaceButton: Equatable, Sendable {
    case a, b, x, y
}

public enum GamepadShoulder: Equatable, Sendable {
    case left, right
}

public enum GamepadDpad: Equatable, Sendable {
    case up, down, left, right
}

public enum GamepadOperatorMap {
    public static func face(_ button: GamepadFaceButton) -> GamepadOperatorAction {
        switch button {
        case .a: .record
        case .b: .recenter
        case .x: .flip
        case .y: .track
        }
    }

    public static func shoulder(_ button: GamepadShoulder) -> GamepadOperatorAction {
        switch button {
        case .left: .zoomChipOut
        case .right: .zoomChipIn
        }
    }

    public static func dpad(_ direction: GamepadDpad) -> GamepadOperatorAction {
        switch direction {
        case .up: .isoUp
        case .down: .isoDown
        case .left: .shutterOpen
        case .right: .shutterClose
        }
    }
}

/// Controls **Gimbal joystick**. Default Left. The other analog stick must not drive.
public enum GamepadGimbalStick: String, CaseIterable, Sendable {
    case left
    case right

    public static let `default`: Self = .left

    public var label: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        }
    }

    public static func parse(_ raw: String?) -> Self {
        switch raw?.lowercased() {
        case right.rawValue: .right
        default: .left
        }
    }

    public static func fromLabel(_ label: String) -> Self {
        label == right.label ? .right : .left
    }

    public func axes(
        leftX: Double, leftY: Double, rightX: Double, rightY: Double
    ) -> (x: Double, y: Double) {
        switch self {
        case .left: (leftX, leftY)
        case .right: (rightX, rightY)
        }
    }

    /// Changing selection must rest a held throw from the previously selected stick.
    public static func restHeldMotion(from previous: Self, to current: Self, driving: Bool) -> Bool
    {
        previous != current && driving
    }
}

/// Angle HUD and D-pad 1/N steps share this resolution. Stepping stays `camcap_shutter`.
public enum GamepadShutterSync: Sendable {
    /// Angle is the operator's intent: the preferred angle while the live 1/N is the nearest legal
    /// speed for it at the live rate, and throughout a format or shutter change still settling (a
    /// rate and a speed from two moments are no angle). Otherwise the nearest live label.
    public static func angleLabel(
        denom: Int, fps: Int, available: [Int], preferredAngle: Double, settling: Bool = false
    ) -> String {
        let preferred = ShutterAngle.label(ShutterAngle.nearestDegrees(preferredAngle))
        guard denom > 0, !settling else { return preferred }
        let mapped = ShutterAngle.denom(
            degrees: preferredAngle, fps: fps, available: available)
        guard mapped != denom, let live = ShutterAngle.nearestLabel(denom: denom, fps: fps) else {
            return preferred
        }
        return live
    }

    public static func shouldPersistPreferredAngle(
        usesAngle: Bool, isPhoto: Bool, expoIsAuto: Bool
    ) -> Bool {
        usesAngle && !isPhoto && !expoIsAuto
    }

    /// After a legal 1/N step, persist this so fps rematch keeps the displayed angle. `nil` when
    /// the frame rate is unknown: nothing is persisted from a guessed angle.
    public static func preferredAngle(afterDenom denom: Int, fps: Int) -> Double? {
        ShutterAngle.degrees(denom: denom, fps: fps).map(ShutterAngle.nearestDegrees)
    }
}
