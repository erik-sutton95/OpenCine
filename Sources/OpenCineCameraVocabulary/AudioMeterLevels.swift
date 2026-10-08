import OpenCineMedia

// The stereo dBFS meter values the camera status carries are OpenCineMedia's (one implementation;
// these were byte-identical copies). The DJI segment decode lives in OpenCineDJI.
public typealias AudioMeterChannel = MonitorAudioMeterChannel
public typealias AudioMeterLevels = MonitorAudioMeterLevels
public typealias AudioMeterBallistics = MonitorAudioMeterBallistics

// Preserve the former native adapter call surface after sharing the same meter value.
extension MonitorAudioMeterLevels {
    public init(_ levels: MonitorAudioMeterLevels) { self = levels }
}
