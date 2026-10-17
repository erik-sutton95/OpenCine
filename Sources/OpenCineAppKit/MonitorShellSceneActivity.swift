#if os(iOS)
import SwiftUI
import UIKit

extension View {
    /// Scene phase and UIKit bounces report to the same deduplicating shell owner.
    public func monitorShellSceneActivity(_ shell: ShellModel) -> some View {
        modifier(MonitorShellSceneActivity(shell: shell))
    }
}

extension ShellModel {
    /// For UI review fixtures: launch state that a live scene owns (a running programmed move)
    /// is set now and again when the app first becomes active, because the launch's inactive
    /// phase retires it exactly as it would retire a real one.
    public static func applyThroughLaunch(_ apply: @escaping @MainActor @Sendable () -> Void) {
        apply()
        final class Observation: @unchecked Sendable { var token: NSObjectProtocol? }
        let observation = Observation()
        observation.token = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { apply() }
            if let token = observation.token { NotificationCenter.default.removeObserver(token) }
            observation.token = nil
        }
    }
}

private struct MonitorShellSceneActivity: ViewModifier {
    let shell: ShellModel
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content
            .onChange(of: phase, initial: true) { _, phase in shell.setSceneActive(phase == .active) }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                shell.setSceneActive(false)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                shell.setSceneActive(true)
            }
    }
}
#endif
