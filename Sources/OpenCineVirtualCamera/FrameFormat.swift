/// Validates a discrete frame-duration request before changing the active format.
public struct FrameFormat {
    public enum Invalid: Error { case unsupported }
    public private(set) var index = 0
    public init() {}

    public mutating func select(
        index: Int?, durationNumerator: Int64?, durationTimescale: Int32?
    ) throws {
        var candidate = index ?? self.index
        guard candidate == 0 || candidate == 1 else { throw Invalid.unsupported }
        if let numerator = durationNumerator, let timescale = durationTimescale {
            guard numerator > 0, timescale > 0 else { throw Invalid.unsupported }
            if timescale % 30 == 0, numerator == Int64(timescale / 30) {
                candidate = 0
            } else if timescale % 60 == 0, numerator == Int64(timescale / 60) {
                candidate = 1
            } else {
                throw Invalid.unsupported
            }
        } else if durationNumerator != nil || durationTimescale != nil {
            throw Invalid.unsupported
        }
        self.index = candidate
    }
}
