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
            setShowOnMonitor: { [weak self] in self?.setShowOnMonitor($0) })
    }

    /// The monitor controls' actions.
    public var monitorActions: LiveStreamMonitorActions {
        LiveStreamMonitorActions(
            start: { [weak self] in self?.start() },
            stop: { [weak self] in self?.stop() },
            restart: { [weak self] in self?.restart() },
            dismissNotice: { [weak self] in self?.dismissNotice() })
    }
}

/// The Go live control, status, notice and warning over the monitor picture. Place it top center
/// over the picture; it draws nothing while the control is hidden.
public struct LiveStreamMonitorOverlay: View {
    let coordinator: LiveStreamCoordinator

    public init(coordinator: LiveStreamCoordinator) { self.coordinator = coordinator }

    public var body: some View {
        if let state = coordinator.monitorState {
            LiveStreamMonitorControls(state: state, actions: coordinator.monitorActions)
                .padding(.top, 10).padding(.horizontal, 16)
        }
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
    /// and heat or a low battery warn while live without stopping it.
    @MainActor @ViewBuilder public func liveStreamLifecycle(_ coordinator: LiveStreamCoordinator?) -> some View {
        if let coordinator {
            modifier(LiveStreamLifecycleModifier(coordinator: coordinator))
        } else {
            self
        }
    }
}

@MainActor private struct LiveStreamLifecycleModifier: ViewModifier {
    let coordinator: LiveStreamCoordinator
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content
            .onChange(of: phase) { _, value in
                guard value == .background, coordinator.isRunning else { return }
                // A short task lets the polite goodbye reach the server before suspension.
                let task = UIApplication.shared.beginBackgroundTask(withName: "live-stream-end", expirationHandler: nil)
                coordinator.sceneDidEnterBackground()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
                }
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
