import OpenCineCameraVocabulary

extension PTPCameraPropertySnapshot {
    /// The body's exposure indicator as the shared exposure meter reads it: the needle in stops
    /// (the body reports sixths) while the indicator is lit. Unknown before the first report and
    /// while the body reports it unlit, because the value is undefined then.
    public var exposureMeter: ExposureMeterReading {
        guard evIndicatorLit != false, let sixths = evIndicatorSixths else {
            return ExposureMeterReading(stops: nil)
        }
        return ExposureMeterReading(stops: Double(sixths) / 6)
    }
}
