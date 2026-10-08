#if os(iOS)
import SwiftUI
import UIKit

extension View {
    /// Scene phase and UIKit bounces report to the same deduplicating shell owner.
    public func monitorShellSceneActivity(_ shell: ShellModel) -> some View {
        modifier(MonitorShellSceneActivity(shell: shell))
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
