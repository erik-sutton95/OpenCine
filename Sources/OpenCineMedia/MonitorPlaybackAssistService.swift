import Foundation

/// The existing native player supplies audio/effects for its captured item. This is not a
/// transport or decoder owner; missing meter samples remain unknown.
@MainActor public protocol MonitorPlaybackAssistService: AnyObject {
    var audioLevels: MonitorAudioMeterLevels? { get }
    func activate()
    func synchronize(item: MonitorPlaybackItemToken, effects: MonitorFrameEffects,
        audioVisible: Bool, outputMuted: Bool,
        ifCurrent: @escaping @MainActor () -> Bool)
    func close()
}
