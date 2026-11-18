import Foundation
import OpenCineCore

/// Chooses the picture for each output frame, so the encoder runs at one fixed rate whatever the
/// source does: the newest picture is used (a slower source repeats, a faster one skips), and once
/// no picture has arrived for `slateAfter` the output shows a neutral slate until pictures return.
/// The stream and its audio stay up meanwhile.
public struct StreamFramePacer<Picture> {
    public enum Frame {
        case picture(Picture)
        case slate
    }

    public let slateAfter: Duration
    private var newest: (picture: Picture, at: MonotonicInstant)?

    public init(slateAfter: Duration = .seconds(2)) {
        self.slateAfter = slateAfter
    }

    public mutating func submit(_ picture: Picture, at now: MonotonicInstant) {
        newest = (picture, now)
    }

    public func frame(at now: MonotonicInstant) -> Frame {
        guard let newest, now - newest.at < slateAfter else { return .slate }
        return .picture(newest.picture)
    }
}

extension StreamFramePacer: Sendable where Picture: Sendable {}
extension StreamFramePacer.Frame: Sendable where Picture: Sendable {}
extension StreamFramePacer.Frame: Equatable where Picture: Equatable {}
