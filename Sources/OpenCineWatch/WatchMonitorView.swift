#if os(watchOS)
import OpenCineRelay
import SwiftUI

/// Compatibility projection of the existing relay reports into the common wrist screen.
public struct WatchMonitorView: View {
    @Environment(WatchSessionController.self) private var controller
    private let openOnIPhone: String

    public init(openOnIPhone: String) { self.openOnIPhone = openOnIPhone }

    public var body: some View {
        WatchOperatorScreen(value: presentation, image: controller.feedImage, action: send)
    }

    private var presentation: WatchMonitorPresentation {
        let state = controller.state
        let clock = state?.connection == .noCamera ? state?.timecode : controller.frameTimecode ?? state?.timecode
        return WatchMonitorPresentation(sourceRevision: controller.presentationRevision,
            header: clock.flatMap { $0.isEmpty ? nil : $0 } ?? "--:--:--",
            media: state?.media, battery: .measured(state?.batteryReading, exhausted: state?.batteryExhausted),
            recording: state?.isRecording, photography: state?.isPhotography,
            feedAspectRatio: state?.feedAspectRatio,
            canCapture: controller.isReachable && state?.connection == .connected && !controller.isSendingCommand,
            placeholder: WatchMonitorPlaceholder.resolve(isReachable: controller.isReachable,
                state: state, hasFeed: controller.feedImage != nil).copy(openOnIPhone: openOnIPhone),
            commandMessage: controller.commandMessage)
    }

    private func send(_ action: WatchMonitorAction) {
        guard presentation.admits(action) else { return }
        switch action.intent {
        case .capture: controller.sendCapture()
        case .record: controller.sendToggleRecord()
        }
    }
}
#endif
