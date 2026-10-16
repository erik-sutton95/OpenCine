import Foundation

/// A Settings browser link through the app's one internet hop (A2-22). On the camera network it
/// leaves, waits for an internet route and keeps the hop while the browser has the person; the
/// camera comes back when the app returns after the browser really took it to the background, or
/// at once when the browser did not open the page. Off the camera network nothing hops.
@available(macOS 14, *) @MainActor
public final class MonitorBrowserInternetHandoff<Route> {
    private let hop: MonitorInternetHop<Route>
    private var held: MonitorInternetHop<Route>.Token?
    private var sawBackground = false

    public init(hop: MonitorInternetHop<Route>) { self.hop = hop }

    /// A browser page holds the hop until the person comes back.
    public var isHolding: Bool { held != nil }

    /// Prepares one page: nil when refused, the hop is busy or no internet route appeared (the
    /// camera is rejoined first). The handoff's completion with `false` comes back at once.
    public func prepare(
        route: Route?, admission: @escaping @MainActor () -> Bool
    ) async -> MonitorSettingsBrowserHandoff? {
        guard admission() else { return nil }
        guard hop.onCameraNetwork else { return .init(isCurrent: { admission() }, complete: { _ in }) }
        guard let route, let token = hop.begin(route, admission: admission) else { return nil }
        guard await hop.waitForInternet(token), hop.owns(token), admission() else {
            await hop.end(token)?.value
            return nil
        }
        held = token
        sawBackground = false
        return .init(
            isCurrent: { [weak self] in
                guard let self, self.hop.owns(token) else { return false }
                return admission() && self.hop.owns(token)
            },
            complete: { [weak self] accepted in
                guard let self, !accepted else { return }
                if self.held == token { self.held = nil; self.sawBackground = false }
                await self.hop.end(token)?.value
            })
    }

    /// The app went to the background while a page holds the hop: the browser has the person.
    public func enteredBackground() {
        if held != nil { sawBackground = true }
    }

    /// The app is active again. After a real trip to the browser, the hop ends and the camera
    /// comes back; a mere activation flicker while the page opens changes nothing.
    @discardableResult public func becameActive() -> Task<Void, Never>? {
        guard let token = held, sawBackground else { return nil }
        held = nil
        sawBackground = false
        return hop.end(token)
    }
}

#if os(iOS)
import SwiftUI
import UIKit

extension View {
    /// Reports background and return to the app's browser handoff (A2-22).
    public func monitorBrowserHandoffReturn<Route>(_ handoff: MonitorBrowserInternetHandoff<Route>) -> some View {
        onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            handoff.enteredBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            handoff.becameActive()
        }
    }
}
#endif
