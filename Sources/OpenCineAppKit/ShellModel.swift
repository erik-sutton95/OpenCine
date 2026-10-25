import Foundation
import Observation
import OpenCineCore

/// The app's root state over `CamerasModel` (SHELL-03): which page shows (cameras, pair or the
/// monitor), an optional cover over it, and the lifetime of the monitor's camera.
///
/// - A successful connect from `cameras` presents its session on the monitor; this shell then owns
///   it. A newer camera replaces the monitor: the old owned session closes as `.replaced`, and
///   everything still in flight for it is retired (`MonitorControlModel.unbind()`).
/// - `close()` leaves the monitor: it retires presentation and editors, closes the session only
///   when this shell owns it, and returns a borrowed one with its `release` (never CloseSession,
///   never stop-record). Closing twice does nothing.
/// - A cover (settings, media) never implies disconnect: the monitor and its session stay. A new
///   monitor (a connect) starts uncovered.
/// - The session ending on its own (`.disconnected`) leaves the monitor; transport recovery is the
///   integration's, so `.recovering` keeps it (with the last reported values).
/// - The scene's active state arrives here once per change, however many OS signals report it.
///
/// Kotlin mirror: `ShellModel` in `:appkit`, same names.
@available(macOS 14, *)
@MainActor
@Observable
public final class ShellModel {
    public enum Route: Hashable, Sendable {
        case cameras
        case pair
        case monitor
    }

    /// A page over the current route. Covering is not leaving.
    public enum Cover: Hashable, Sendable {
        case settings
        case media
    }

    /// The camera on the monitor and who owns its session.
    public struct Monitor: Identifiable {
        public enum Ownership {
            /// This shell closes it.
            case owned
            /// Lent by another owner (a multicam member); `release` hands it back.
            case borrowed(release: @MainActor () -> Void)
        }

        /// One monitor lifetime: a host keyed by it is created once and survives covers.
        public let id = UUID()
        public let camera: ConnectedCamera
        public let ownership: Ownership
        public var session: any CameraSession { camera.session }
        public var isBorrowed: Bool {
            if case .borrowed = ownership { return true }
            return false
        }
    }

    public let cameras: CamerasModel
    public let control: MonitorControlModel
    public private(set) var monitor: Monitor?
    public private(set) var cover: Cover?
    /// The operator opened the pair page (it also shows while nothing is saved).
    public private(set) var pairing = false
    /// The operator chose the cameras page with nothing saved (to watch a feed, say): an empty
    /// list shows it instead of the pair page.
    public private(set) var camerasChosen = false
    /// The app's scene is active. Starts active.
    public private(set) var sceneActive = true
    /// Called once per change of `sceneActive`.
    @ObservationIgnored public var onSceneActivity: (Bool) -> Void = { _ in }
    /// Monitor hosts mounted and unmounted by `AppShell` (one per monitor lifetime).
    @ObservationIgnored public private(set) var hostsMounted = 0
    @ObservationIgnored public private(set) var hostsUnmounted = 0

    /// Takes over `cameras.onConnected`: each connect presents its camera.
    public init(cameras: CamerasModel, control: MonitorControlModel = MonitorControlModel()) {
        self.cameras = cameras
        self.control = control
        cameras.onConnected = { [weak self] camera in self?.present(camera) }
        control.onEnded = { [weak self] in self?.sessionEnded() }
    }

    public var route: Route {
        if monitor != nil { return .monitor }
        return pairing || (cameras.saved.isEmpty && !camerasChosen) ? .pair : .cameras
    }

    // MARK: Monitor lifetime

    /// Shows `camera` on the monitor; this shell owns and later closes its session.
    public func present(_ camera: ConnectedCamera) {
        // A delayed connection callback for the already-presented session is not a replacement.
        // Keep its picture host, ownership, cover and open editors intact.
        guard monitor?.session.id != camera.session.id else { return }
        show(Monitor(camera: camera, ownership: .owned))
    }

    /// Shows a session another owner lends; `close()` calls `release` instead of closing it.
    public func borrow(_ camera: ConnectedCamera, release: @escaping @MainActor () -> Void) {
        show(Monitor(camera: camera, ownership: .borrowed(release: release)))
    }

    /// What leaving the monitor does to an open cover.
    public enum CoverRetention: Sendable {
        /// The cover leaves with the monitor (the default).
        case dismiss
        /// The cover stays, with its view state, over the cameras page: an internet hop leaves
        /// the camera with the gallery still open (A2-07).
        case retain
    }

    /// Leaves the monitor for the cameras page. Closes the session only when owned.
    public func close() { close(.dismiss) }

    /// `close()`, with the cover kept over the cameras page when `cover` is `.retain`.
    public func close(_ cover: CoverRetention) {
        guard let monitor = leave(cover) else { return }
        end(monitor, closing: .requested)
    }

    private func show(_ next: Monitor) {
        if let previous = leave() { end(previous, closing: .replaced) }
        monitor = next
        // A connect shows the monitor, never a leftover page.
        cover = nil
        pairing = false
        control.bind(next.session)
    }

    /// The session ended by itself (closed, link given up): nothing to close.
    private func sessionEnded() {
        guard let monitor = leave() else { return }
        end(monitor, closing: nil)
    }

    private func leave(_ retention: CoverRetention = .dismiss) -> Monitor? {
        guard let monitor else { return nil }
        control.unbind()
        self.monitor = nil
        if retention == .dismiss { cover = nil }
        return monitor
    }

    private func end(_ monitor: Monitor, closing reason: SessionCloseReason?) {
        switch monitor.ownership {
        case .owned:
            if let reason {
                let session = monitor.session
                Task { await session.close(reason) }
            }
            // A replacement keeps the connection model's camera; anything else resumes discovery.
            if reason != .replaced { cameras.sessionEnded() }
        case .borrowed(let release):
            release()
        }
    }

    // MARK: Navigation

    public func beginPairing() { pairing = true }
    public func endPairing() { pairing = false }

    /// Leaves pairing for the cameras page, which stays even with nothing saved.
    public func showCameras() {
        pairing = false
        camerasChosen = true
    }

    /// Opens `cover` over the current page; the monitor and its session stay.
    public func open(_ cover: Cover) { self.cover = cover }
    public func dismissCover() { cover = nil }

    /// The camera body's own gallery, as a camera maker's app shows it: the body entering it
    /// opens Media, and the body leaving it closes Media (which returns the camera to live).
    /// Another cover the operator opened stays.
    public func followCameraGallery(open: Bool) {
        if open, cover == nil {
            self.open(.media)
        } else if !open, cover == .media {
            dismissCover()
        }
    }

    // MARK: Scene

    /// The OS reports the scene active or not (scene phase, app notifications, lifecycle).
    public func setSceneActive(_ active: Bool) {
        guard active != sceneActive else { return }
        sceneActive = active
        // The Local Network prompt and a Settings visit both end here: re-check that permission.
        if active { cameras.retryLocalNetworkFailures() }
        onSceneActivity(active)
    }

    // MARK: Host accounting (diagnostics)

    func noteHost(mounted: Bool) {
        if mounted { hostsMounted += 1 } else { hostsUnmounted += 1 }
    }
}
