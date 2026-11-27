import Foundation
import OpenCineDesktopKit

/// What the "OpenCine" input shows: the selected slot's picture under that slot's own rules, so
/// its clean frame, or the same slate the slot's input shows when the camera is not live. A new
/// selection takes effect on the next output, on the same device, so a receiving app never
/// reconnects. All calls must use the driver's serial delivery queue.
public final class SelectedInputRouter<Frame: AnyObject> {
    public struct Picture {
        /// The slot shown, or `nil` when none is selected or the driver has no input for it.
        public let slot: VirtualCameraSlot?
        public let output: FramePolicy<Frame>.Output
    }

    public private(set) var selection = VirtualCameraSelection(slot: nil)

    public init() {}

    /// Follows the dock's selection. Returns true when it changed.
    @discardableResult
    public func select(_ selection: VirtualCameraSelection) -> Bool {
        guard selection != self.selection else { return false }
        self.selection = selection
        return true
    }

    /// The picture for this output. `policy` gives a published slot's frame policy.
    public func output(now: UInt64, policy: (VirtualCameraSlot) -> FramePolicy<Frame>?) -> Picture {
        guard let slot = selection.slot, let source = policy(slot) else {
            return Picture(slot: nil, output: .slate(.feedOff))
        }
        return Picture(slot: slot, output: source.peek(now: now))
    }
}
