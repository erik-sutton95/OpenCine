#if os(iOS)
import AVFoundation
import MediaPlayer
import MonitorUI
import OpenCineAppKit
import OSLog
import SwiftUI
import UIKit

/// The volume-button remote shutter (A2-32): turns a paired Bluetooth shutter remote's press, or
/// the phone's own volume buttons, into one record toggle while the live view is in front. An app
/// offers it with one typed declaration: `MonitorSettingsRemoteShutter.volumeButtons(enabled:)` in
/// its Controls input source, and either `.monitorRemoteShutter(...)` at its root or, when the
/// host already coordinates the audio session, this owner reconciled from its model.
///
/// Third-party shutter buttons pair as HID keyboards and send Consumer-Control volume presses
/// (some models up, some down) that iOS routes to the system volume; there is no key event to
/// catch. While active: documented KVO on `AVAudioSession.outputVolume` observes the change, an
/// `MPVolumeView` in the window suppresses the system volume HUD, and after every press the
/// volume is re-anchored at the operator's own level so presses in either direction register and
/// the audible volume never drifts. Re-anchoring through the volume view's slider is a best-effort
/// compatibility technique, not a documented interception API; a private volume-change
/// notification remains only as a best-effort rail fallback. The rules (when to listen, what is a
/// press) are `MonitorRemoteShutterPolicy`.
///
/// This takes over the volume buttons, so it only runs while the operator has opted in and the
/// live monitor is in front; the pre-session volume is restored on stop. It needs no
/// `AVCaptureSession`: an always-running capture session would cost a camera permission prompt,
/// the camera-in-use indicator and thermal and radio load during live view.
@MainActor
public final class MonitorRemoteShutter {
    /// The Controls row title and help every app shows for this owner.
    public static let title = "Bluetooth Remote Shutter"
    public static let help =
        "A paired Bluetooth shutter remote's button press starts or stops recording while the live view is up front. Inside Settings, Media, or other full-screen pages the volume keys behave normally. The phone's volume keys record too, and Record Confirmation is skipped. Presses arrive as volume commands, so the volume may move momentarily before snapping back; the system volume overlay stays hidden while armed."

    /// The host's log, named by its subsystem.
    public let log: Logger
    /// Called on each press (either direction), already debounced. A remote press skips the
    /// phone-side record confirmation: an unseen dialog would strand the take.
    public var onTrigger: (@MainActor () -> Void)?
    public private(set) var isActive = false

    /// Undocumented MediaPlayer notification used only as a best-effort supplement to the public
    /// `outputVolume` observer. Its name and userInfo contract can vary between iOS releases.
    private nonisolated static let volumeNotification = Notification.Name("SystemVolumeDidChange")

    private var presses = MonitorRemoteShutterPresses(volume: 0.5)
    private var volumeObservation: NSKeyValueObservation?
    private var volumeObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var volumeView: MPVolumeView?
    private var volumeSlider: UISlider?
    private var sliderAcquisitionTask: Task<Void, Never>?
    private var sliderAcquisitionGeneration = 0
    private var volumeWriteTask: Task<Void, Never>?
    private var routeRecoveryTask: Task<Void, Never>?
    private var restoreVolumesByRoute: [String: Float] = [:]
    private var suppressVolumeEventsUntil: TimeInterval = 0
    private var outputRouteSignature = ""
    private var eventGeneration = 0

    public init(subsystem: String, category: String = "bluetooth-shutter") {
        log = Logger(subsystem: subsystem, category: category)
    }

    /// Starts or stops listening to match the host's state. Idempotent: call it from every seam
    /// that changes an input (preference, monitor presented or covered, foreground return, a clip
    /// player taking the audio session). Returns whether it listens.
    @discardableResult
    public func update(
        enabled: Bool, monitorPresented: Bool, liveViewFront: Bool, audioSessionAvailable: Bool = true
    ) -> Bool {
        let shouldRun = MonitorRemoteShutterPolicy.shouldRun(
            enabled: enabled, monitorPresented: monitorPresented, liveViewFront: liveViewFront,
            applicationIsActive: UIApplication.shared.applicationState == .active,
            audioSessionAvailable: audioSessionAvailable)
        log.info(
            "BT-SHUTTER reconcile enabled=\(enabled, privacy: .public) monitor=\(monitorPresented, privacy: .public) shouldRun=\(shouldRun, privacy: .public) kvoActive=\(self.isActive, privacy: .public)"
        )
        guard shouldRun else {
            stop()
            return false
        }
        let armed = start()
        log.info("BT-SHUTTER volume monitor armed=\(armed, privacy: .public)")
        return armed
    }

    @discardableResult
    private func start() -> Bool {
        guard UIApplication.shared.applicationState == .active else {
            log.info("BT-SHUTTER start deferred: app is not active")
            return false
        }
        if isActive {
            guard activateAudioSession() else {
                stop()
                return false
            }
            installVolumeView()
            beginSliderAcquisition()
            log.info("BT-SHUTTER reactivated existing monitor")
            return true
        }
        guard activateAudioSession() else { return false }

        let session = AVAudioSession.sharedInstance()
        isActive = true
        eventGeneration += 1
        outputRouteSignature = Self.outputRouteSignature(for: session)
        restoreVolumesByRoute = [outputRouteSignature: session.outputVolume]
        // Taken from where the operator left it, so for almost everyone the monitor opening
        // changes nothing they can hear.
        presses.reanchor(volume: session.outputVolume)
        installVolumeView()
        beginSliderAcquisition()
        // `outputVolume` KVO is Apple's documented observation path. It is the primary detector;
        // the notification below merely supplements it at the 0/1 rails. Both feed the same
        // debounce, so an OS that emits both still produces exactly one record toggle.
        let log = log
        volumeObservation = session.observe(\.outputVolume, options: [.old, .new]) {
            [weak self] session, change in
            let newValue = change.newValue ?? session.outputVolume
            let oldText = change.oldValue.map { String($0) } ?? "nil"
            log.info(
                "BT-SHUTTER KVO old=\(oldText, privacy: .public) new=\(newValue, privacy: .public)"
            )
            Task { @MainActor [weak self] in
                self?.volumeChanged(to: newValue, source: "KVO")
            }
        }
        // Weak self crosses into the @Sendable observer block via an @unchecked Sendable box
        // (Swift 6 dynamic isolation): the block runs on the main queue, so assumeIsolated is sound.
        let box = ShutterSendableBox(value: { [weak self] name, keys, reason, volume in
            self?.handleVolumeNotification(
                name: name, keys: keys, reason: reason, volume: volume)
        })
        volumeObserver = NotificationCenter.default.addObserver(
            forName: Self.volumeNotification, object: nil, queue: .main
        ) { notification in
            let info = notification.userInfo ?? [:]
            let reason = info["Reason"] as? String
            let rawVolume = info["Volume"]
            let volume: Float?
            switch rawVolume {
            case let value as Float: volume = value
            case let value as Double: volume = Float(value)
            case let value as NSNumber: volume = value.floatValue
            default: volume = nil
            }
            let keys = info.keys.map { String(describing: $0) }.sorted().joined(separator: ",")
            let name = notification.name.rawValue
            MainActor.assumeIsolated { box.value(name, keys, reason, volume) }
        }
        let routeBox = ShutterRouteSendableBox(value: { [weak self] in
            self?.audioRouteChanged()
        })
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { _ in
            MainActor.assumeIsolated { routeBox.value() }
        }
        log.info(
            "BT-SHUTTER started category=\(session.category.rawValue, privacy: .public) volume=\(session.outputVolume, privacy: .public)"
        )
        return true
    }

    /// Stops listening and restores the volume the route had before; safe when idle.
    public func stop() {
        guard isActive else { return }
        isActive = false
        eventGeneration += 1
        sliderAcquisitionGeneration += 1
        sliderAcquisitionTask?.cancel()
        sliderAcquisitionTask = nil
        volumeWriteTask?.cancel()
        volumeWriteTask = nil
        routeRecoveryTask?.cancel()
        routeRecoveryTask = nil
        volumeObservation?.invalidate()
        volumeObservation = nil
        if let volumeObserver { NotificationCenter.default.removeObserver(volumeObserver) }
        volumeObserver = nil
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        // The slider is already established at shutdown, so restore synchronously while this
        // monitor still owns an active audio session. Delayed writes can otherwise race a new
        // activation or deactivate the clip player's session after a rapid surface transition.
        let currentRouteSignature = Self.outputRouteSignature(
            for: AVAudioSession.sharedInstance())
        if let restoreVolume = restoreVolumesByRoute[currentRouteSignature], let volumeSlider {
            volumeSlider.setValue(restoreVolume, animated: false)
            log.info(
                "BT-SHUTTER restored volume=\(restoreVolume, privacy: .public)")
        }
        restoreVolumesByRoute.removeAll()
        outputRouteSignature = ""
        let view = volumeView
        volumeView = nil
        volumeSlider = nil
        view?.removeFromSuperview()
        do {
            try AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation)
        } catch {
            log.error(
                "BT-SHUTTER deactivation failed: \(error.localizedDescription, privacy: .public)")
        }
        log.info("BT-SHUTTER stopped")
    }

    private func volumeChanged(to newValue: Float, source: String) {
        // Route notifications originate on a secondary thread and KVO has independent delivery
        // ordering. Give both a short turn to settle, then also compare the live route signature
        // before interpreting a volume move as a shutter press.
        let generation = eventGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.1))
            guard !Task.isCancelled, let self, self.eventGeneration == generation else { return }
            self.adjudicateVolumeChange(newValue, source: source)
        }
    }

    private func adjudicateVolumeChange(_ newValue: Float, source: String) {
        // KVO reports every system-volume change, including Control Center adjustments while this
        // app is covered/inactive. Only a frontmost live monitor may turn one into a record command.
        guard isActive, UIApplication.shared.applicationState == .active else {
            log.info(
                "BT-SHUTTER ignored \(source, privacy: .public) event while inactive")
            return
        }
        let currentRouteSignature = Self.outputRouteSignature(for: .sharedInstance())
        if currentRouteSignature != outputRouteSignature {
            handleAudioRouteChange(signature: currentRouteSignature)
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        if now < suppressVolumeEventsUntil {
            log.info(
                "BT-SHUTTER ignored \(source, privacy: .public) event during audio-route change")
            if abs(newValue - presses.anchor) > 0.001 { setSystemVolume(presses.anchor) }
            return
        }
        let decision = presses.observe(volume: newValue, at: now)
        log.info(
            "BT-SHUTTER event source=\(source, privacy: .public) volume=\(newValue, privacy: .public) decision=\(decision.rawValue, privacy: .public)"
        )
        guard decision == .trigger else {
            // Debounced repeat or an echo drift: re-pin so the volume never walks to a rail.
            if presses.repins(volume: newValue, at: now) { setSystemVolume(presses.anchor) }
            return
        }
        setSystemVolume(presses.anchor)
        log.info("BT-SHUTTER dispatching record toggle")
        onTrigger?()
    }

    private func activateAudioSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            // A Bluetooth shutter changes the media output volume. `.playback` puts this app on
            // that route; mixing keeps other audio uninterrupted while the opt-in is active.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            return true
        } catch {
            log.error(
                "BT-SHUTTER activation failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func handleVolumeNotification(
        name: String, keys: String, reason: String?, volume: Float?
    ) {
        log.info(
            "BT-SHUTTER notification name=\(name, privacy: .public) keys=\(keys, privacy: .public) reason=\(reason ?? "nil", privacy: .public) volume=\(volume.map { String($0) } ?? "nil", privacy: .public)"
        )
        guard reason == "ExplicitVolumeChange", let volume else { return }
        volumeChanged(to: volume, source: "notification")
    }

    private func audioRouteChanged() {
        handleAudioRouteChange(
            signature: Self.outputRouteSignature(for: AVAudioSession.sharedInstance()))
    }

    private func handleAudioRouteChange(signature: String) {
        // Each route remembers its own output volume. Connecting headphones or another Bluetooth
        // route can therefore move outputVolume without a shutter press; suppress that transition
        // and rebuild MPVolumeView because its internal slider may be replaced for the new route.
        guard isActive else { return }
        guard signature != outputRouteSignature else {
            suppressVolumeEventsUntil = CFAbsoluteTimeGetCurrent() + 0.8
            log.info(
                "BT-SHUTTER same audio route changed category; suppressing volume events")
            return
        }
        outputRouteSignature = signature
        suppressVolumeEventsUntil = CFAbsoluteTimeGetCurrent() + 0.8
        log.info("BT-SHUTTER audio route changed; suppressing volume events")
        volumeWriteTask?.cancel()
        volumeWriteTask = nil
        sliderAcquisitionGeneration += 1
        sliderAcquisitionTask?.cancel()
        sliderAcquisitionTask = nil
        volumeSlider = nil
        volumeView?.removeFromSuperview()
        volumeView = nil
        routeRecoveryTask?.cancel()
        routeRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.2))
            guard !Task.isCancelled, let self, self.isActive else { return }
            let routeVolume = AVAudioSession.sharedInstance().outputVolume
            if self.restoreVolumesByRoute[signature] == nil {
                self.restoreVolumesByRoute[signature] = routeVolume
            }
            // Every route remembers its own level, so the anchor is re-derived rather than
            // carried across; otherwise plugging in headphones would drag their volume to
            // whatever the speaker happened to be at.
            self.presses.reanchor(volume: routeVolume)
            self.installVolumeView()
            self.beginSliderAcquisition()
            self.routeRecoveryTask = nil
        }
    }

    private static func outputRouteSignature(for session: AVAudioSession) -> String {
        session.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.uid)" }
            .sorted()
            .joined(separator: "|")
    }

    /// An `MPVolumeView` in the window suppresses the system volume HUD. This implementation also
    /// uses its internal slider as a best-effort re-anchor; iOS does not expose a documented API
    /// for intercepting generic HID volume commands without first changing system volume. The view
    /// must be genuinely in the visible hierarchy for HUD suppression to hold on device, so it
    /// sits at 1×1 pt in a corner at near-zero alpha rather than offscreen.
    private func installVolumeView() {
        guard volumeView == nil else { return }
        guard
            let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        else {
            log.error("BT-SHUTTER volume view has no key window")
            return
        }
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.alpha = 0.02
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        window.addSubview(view)
        volumeView = view
        log.info("BT-SHUTTER volume view installed")
    }

    /// `MPVolumeView` builds its slider subview asynchronously after joining the hierarchy:
    /// searching too early finds nothing (and silently broke anchoring in the first cut of this
    /// feature). Poll briefly until it appears, then take the initial anchor.
    private func beginSliderAcquisition() {
        guard isActive, volumeSlider == nil, sliderAcquisitionTask == nil else { return }
        sliderAcquisitionGeneration += 1
        let generation = sliderAcquisitionGeneration
        sliderAcquisitionTask = Task { @MainActor [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self, self.isActive, self.volumeSlider == nil,
                    self.sliderAcquisitionGeneration == generation
                else { return }
                // Scene activation and MPVolumeView's private hierarchy are both asynchronous.
                if self.volumeView == nil { self.installVolumeView() }
                if let volumeView = self.volumeView,
                    let slider = Self.firstSlider(in: volumeView)
                {
                    self.volumeSlider = slider
                    self.bluetoothSliderAcquired(slider, attempt: attempt)
                    self.sliderAcquisitionTask = nil
                    return
                }
                if attempt == 20 {
                    log.error(
                        "BT-SHUTTER slider acquisition delayed; continuing to retry")
                }
                attempt += 1
                try? await Task.sleep(for: attempt <= 20 ? .seconds(0.15) : .seconds(1))
            }
        }
    }

    private func bluetoothSliderAcquired(_ slider: UISlider, attempt: Int) {
        log.info(
            "BT-SHUTTER slider acquired class=\(NSStringFromClass(type(of: slider)), privacy: .public) attempt=\(attempt, privacy: .public)"
        )
        setSystemVolume(presses.anchor)
    }

    private func setSystemVolume(_ value: Float) {
        presses.pinned(at: CFAbsoluteTimeGetCurrent())
        // Capture the current slider before the async delay; lifecycle or route teardown may clear
        // the monitor's property while this write is waiting.
        guard let slider = volumeSlider else {
            log.error(
                "BT-SHUTTER cannot set volume=\(value, privacy: .public): slider unavailable")
            return
        }
        log.info(
            "BT-SHUTTER setting volume=\(value, privacy: .public)")
        volumeWriteTask?.cancel()
        volumeWriteTask = Task { @MainActor [weak self, weak slider] in
            // The slider ignores writes for a beat after appearing; a short defer makes them stick.
            try? await Task.sleep(for: .seconds(0.05))
            guard !Task.isCancelled, let self, self.isActive, let slider else { return }
            slider.setValue(value, animated: false)
            try? await Task.sleep(for: .seconds(0.1))
            guard !Task.isCancelled, self.isActive else { return }
            let actual = AVAudioSession.sharedInstance().outputVolume
            log.info(
                "BT-SHUTTER volume readback requested=\(value, privacy: .public) actual=\(actual, privacy: .public)"
            )
        }
    }

    static func firstSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for subview in view.subviews {
            if let slider = firstSlider(in: subview) { return slider }
        }
        return nil
    }
}

/// Minimal `@unchecked Sendable` box carrying the main-actor volume handler into the notification
/// observer's `@Sendable` block; invoked only on the main actor (the observer queue is `.main`).
private struct ShutterSendableBox: @unchecked Sendable {
    let value: @MainActor (String, String, String?, Float?) -> Void
}

private struct ShutterRouteSendableBox: @unchecked Sendable {
    let value: @MainActor () -> Void
}

extension MonitorSettingsRemoteShutter {
    /// The remote shutter `MonitorRemoteShutter` runs, over the host's stored choice.
    public static func volumeButtons(enabled: Binding<Bool>) -> Self {
        .init(enabled: enabled, title: MonitorRemoteShutter.title, help: MonitorRemoteShutter.help)
    }
}

extension View {
    /// Install once at the app root to offer the remote shutter: while `enabled` and the live view
    /// is in front (no Settings, Media or other full-screen page over it), each press calls
    /// `record` once. A host whose clip player shares the audio session reconciles a
    /// `MonitorRemoteShutter` from its model instead.
    public func monitorRemoteShutter(
        enabled: Bool, liveViewFront: Bool, subsystem: String, record: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(MonitorRemoteShutterModifier(
            enabled: enabled, liveViewFront: liveViewFront, subsystem: subsystem, record: record))
    }
}

@MainActor private struct MonitorRemoteShutterModifier: ViewModifier {
    let enabled: Bool
    let liveViewFront: Bool
    let record: @MainActor () -> Void
    @Environment(\.scenePhase) private var phase
    @State private var owner: MonitorRemoteShutter

    init(enabled: Bool, liveViewFront: Bool, subsystem: String, record: @escaping @MainActor () -> Void) {
        self.enabled = enabled; self.liveViewFront = liveViewFront; self.record = record
        _owner = State(initialValue: MonitorRemoteShutter(subsystem: subsystem))
    }

    func body(content: Content) -> some View {
        content
            .onAppear(perform: reconcile)
            .onChange(of: enabled) { _, _ in reconcile() }
            .onChange(of: liveViewFront) { _, _ in reconcile() }
            .onChange(of: phase) { _, _ in reconcile() }
            .onDisappear { owner.stop() }
    }

    private func reconcile() {
        let record = record
        owner.onTrigger = { record() }
        owner.update(enabled: enabled, monitorPresented: true, liveViewFront: liveViewFront && phase == .active)
    }
}
#endif
