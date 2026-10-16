#if os(iOS)
import OpenCineAppKit
import SwiftUI
import UIKit

/// One root owns native wake requests across changes of foreground surface.
@MainActor public final class MonitorScreenWakeOwner {
    private let apply: @MainActor (Bool) -> Void
    private var applied: Bool?

    public init(apply: @escaping @MainActor (Bool) -> Void = {
        UIApplication.shared.isIdleTimerDisabled = $0
    }) {
        self.apply = apply
    }

    public func update(enabled: Bool, sceneActive: Bool) {
        set(MonitorScreenWakePolicy.keepAwake(enabled: enabled, sceneActive: sceneActive))
    }

    public func retire() {
        set(false)
    }

    private func set(_ value: Bool) {
        guard applied != value else { return }
        applied = value
        apply(value)
    }
}

extension View {
    /// Install once at the app root, above monitor, playback and settings surfaces.
    @MainActor public func monitorScreenWake(enabled: Bool) -> some View {
        modifier(MonitorScreenWakeModifier(enabled: enabled))
    }
}

@MainActor private struct MonitorScreenWakeModifier: ViewModifier {
    let enabled: Bool
    @Environment(\.scenePhase) private var phase
    @State private var owner = MonitorScreenWakeOwner()

    func body(content: Content) -> some View {
        content
            .onAppear { owner.update(enabled: enabled, sceneActive: phase == .active) }
            .onChange(of: enabled) { _, value in
                owner.update(enabled: value, sceneActive: phase == .active)
            }
            .onChange(of: phase) { _, value in
                owner.update(enabled: enabled, sceneActive: value == .active)
            }
            .onDisappear { owner.retire() }
    }
}
#endif
