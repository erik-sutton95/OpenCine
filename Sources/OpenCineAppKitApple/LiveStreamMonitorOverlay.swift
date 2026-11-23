#if os(iOS)
import MonitorPresentation
import MonitorUI
import SwiftUI
import UIKit

extension LiveStreamCoordinator {
    /// The settings card's actions.
    public var settingsActions: LiveStreamSettingsActions {
        LiveStreamSettingsActions(
            selectService: { [weak self] in self?.selectService($0) },
            setServer: { [weak self] in self?.setServer($0) },
            saveKey: { [weak self] in self?.saveKey($0) },
            removeKey: { [weak self] in self?.removeKey() },
            setShowOnMonitor: { [weak self] in self?.setShowOnMonitor($0) },
            selectQuality: { [weak self] in self?.selectQuality($0) })
    }

    /// The monitor controls' actions.
    public var monitorActions: LiveStreamMonitorActions {
        LiveStreamMonitorActions(
            start: { [weak self] in self?.start() },
            stop: { [weak self] in self?.stop() },
            restart: { [weak self] in self?.restart() },
            dismissNotice: { [weak self] in self?.dismissNotice() },
            startOnNetwork: { [weak self] in self?.start(network: $0) },
            retryCamera: { [weak self] in self?.retryCamera() })
    }
}

/// The Go live control, status, notice and warning over the monitor picture. A plain view over
/// the coordinator: hang its top trailing corner at `LiveStreamOverlayPlacement.anchor` (under the
/// timecode block, top right); it draws nothing while the control is hidden. While it is on
/// screen the app-level pill stays hidden.
public struct LiveStreamMonitorOverlay: View {
    let coordinator: LiveStreamCoordinator
    let hidden: Bool

    /// `hidden` steps the control aside (while the zoom ruler is open) without unmounting it, so
    /// the app-level pill stays hidden and nothing about the stream changes.
    public init(coordinator: LiveStreamCoordinator, hidden: Bool = false) {
        self.coordinator = coordinator
        self.hidden = hidden
    }

    public var body: some View {
        ZStack {
            // Keeps the overlay on screen (so appear and disappear report) while the control hides.
            Color.clear.frame(width: 0, height: 0)
            if let state = coordinator.monitorState {
                LiveStreamMonitorControls(state: state, actions: coordinator.monitorActions)
            }
        }
        .monitorHiddenWhileZoom(hidden)
        .onAppear { coordinator.monitorControlsAppeared() }
        .onDisappear { coordinator.monitorControlsDisappeared() }
    }
}

/// The Sharing tab's live stream card over the coordinator.
public struct LiveStreamSettingsSection: View {
    let coordinator: LiveStreamCoordinator
    let feedback: () -> Void

    public init(coordinator: LiveStreamCoordinator, feedback: @escaping () -> Void = {}) {
        self.coordinator = coordinator
        self.feedback = feedback
    }

    public var body: some View {
        LiveStreamSettingsCard(state: coordinator.settingsState, actions: coordinator.settingsActions,
            feedback: feedback)
    }
}

extension View {
    /// Install once at the app root: leaving the app ends the stream (streaming is foreground only),
    /// heat or a low battery warn while live without stopping it, and while a stream runs with no
    /// monitor overlay on screen the shared Live pill shows top center with Stop.
    @MainActor @ViewBuilder public func liveStreamLifecycle(_ coordinator: LiveStreamCoordinator?) -> some View {
        if let coordinator {
            modifier(LiveStreamLifecycleModifier(coordinator: coordinator))
        } else {
            self
        }
    }
}

@MainActor private final class TerminationFlag {
    var done = false
}

/// One background task, ended once (by the work finishing or by its expiration).
@MainActor private final class BackgroundTask {
    var id: UIBackgroundTaskIdentifier = .invalid

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

@MainActor private struct LiveStreamLifecycleModifier: ViewModifier {
    let coordinator: LiveStreamCoordinator
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let pill = coordinator.pillState {
                    LiveStreamPill(state: pill) { coordinator.stop() }.padding(.top, 4)
                }
            }
            .onChange(of: phase) { _, value in
                guard value == .background, coordinator.isRunning else { return }
                // A short task lets the polite goodbye reach the server before suspension.
                let task = BackgroundTask()
                task.id = UIApplication.shared.beginBackgroundTask(withName: "live-stream-end") {
                    MainActor.assumeIsolated { task.end() }
                }
                coordinator.sceneDidEnterBackground()
                // A camera streaming on its own is also told to end (a bounded camera command).
                Task {
                    async let goodbye: Void = Task.sleep(for: .seconds(2))
                    await coordinator.cameraStreamEnded()
                    try? await goodbye
                    task.end()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                // No guard: a camera end still running after the background must go out too.
                // Best effort before the process ends: keep the main run loop turning (the camera's
                // end command runs on the main actor) for at most 4 seconds.
                let ending = TerminationFlag()
                Task { @MainActor in
                    await coordinator.prepareForTermination()
                    ending.done = true
                }
                let deadline = Date().addingTimeInterval(4)
                while !ending.done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            }
            .onChange(of: coordinator.isRunning) { _, running in
                if running { UIDevice.current.isBatteryMonitoringEnabled = true }
                refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
                refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
                refresh()
            }
    }

    private func refresh() {
        let thermal = ProcessInfo.processInfo.thermalState
        let device = UIDevice.current
        let level = device.batteryLevel
        let charging = device.batteryState == .charging || device.batteryState == .full
        coordinator.updateDeviceConditions(
            hot: thermal == .serious || thermal == .critical,
            lowBattery: level >= 0 && level < 0.15 && !charging)
    }
}
#endif
