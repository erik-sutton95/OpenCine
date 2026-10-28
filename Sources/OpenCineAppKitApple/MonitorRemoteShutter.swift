#if os(iOS)
import AVFoundation
import MediaPlayer
import MonitorUI
import OpenCineAppKit
import os
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
/// catch. While active: documented KVO on `AVAudioSession.outputVolume` observes the change, and
/// after every press the volume is re-anchored at the operator's own level so presses in either
/// direction register and the audible volume never drifts. Re-anchoring through an `MPVolumeView`
/// slider is a best-effort compatibility technique, not a documented interception API; the view is
/// only in the window for a short lease around each write, because left there it keeps the app
/// from ever idling. A private volume-change notification remains only as a best-effort rail
/// fallback. The rules (when to listen, what is a press, when the view may stay) are
/// `MonitorRemoteShutterPolicy` and `MonitorRemoteShutterVolumeLease`.
///
/// This takes over the volume buttons, so it only runs while the operator has opted in and the
/// live monitor is in front; the pre-session volume is restored on stop. It needs no
/// `AVCaptureSession`: an always-running capture session would cost a camera permission prompt,
/// the camera-in-use indicator and thermal and radio load during live view.
@MainActor
public final class MonitorRemoteShutter {
    /// The Controls row title and help every app shows for this owner.
    public nonisolated static let title = "Bluetooth Remote Shutter"
    public nonisolated static let help =
        "A paired Bluetooth shutter remote's button press starts or stops recording while the live view is up front. Inside Settings, Media, or other full-screen pages the volume keys behave normally. The phone's volume keys record too, and Record Confirmation is skipped. Presses arrive as volume commands, so the volume overlay may flash and the volume may move momentarily before snapping back."

    /// The host's log, named by its subsystem.
    public let log: Logger
    /// Called on each press (either direction), already debounced. A remote press skips the
    /// phone-side record confirmation: an unseen dialog would strand the take.
    public var onTrigger: (@MainActor () -> Void)?
    public private(set) var isActive = false

    /// Undocumented MediaPlayer notification used only as a best-effort supplement to the public
    /// `outputVolume` observer. Its name and userInfo contract can vary between iOS releases.
    private nonisolated static let volumeNotification = Notification.Name("SystemVolumeDidChange")

    var presses = MonitorRemoteShutterPresses(volume: 0.5)
    private var volumeObservation: NSKeyValueObservation?
    private var volumeObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    let volumeWriter: MonitorRemoteShutterVolumeWriter
    var liveVolume: @MainActor () -> Float = { AVAudioSession.sharedInstance().outputVolume }
    /// A restore that stop() left to the writer (no slider was in hand); a re-arm before it lands
    /// keeps that route's original level instead of the anchor it would otherwise read back.
    private var pendingRestore: (route: String, volume: Float)?
    private var routeRecoveryTask: Task<Void, Never>?
    private var restoreVolumesByRoute: [String: Float] = [:]
    var suppressVolumeEventsUntil: TimeInterval = 0
    private var outputRouteSignature = ""
    private var eventGeneration = 0

    public init(subsystem: String, category: String = "bluetooth-shutter") {
        log = Logger(subsystem: subsystem, category: category)
        volumeWriter = MonitorRemoteShutterVolumeWriter(log: log)
        // The re-anchor's own echo is judged from when the slider actually moved, which with a
        // leased view can be a few hundred milliseconds after the request.
        volumeWriter.onWritten = { [weak self] value in
            guard let self else { return }
            self.presses.pinned(at: CFAbsoluteTimeGetCurrent())
            if !self.isActive, self.pendingRestore?.volume == value { self.pendingRestore = nil }
        }
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
            log.info("BT-SHUTTER reactivated existing monitor")
            return true
        }
        guard activateAudioSession() else { return false }

        let session = AVAudioSession.sharedInstance()
        isActive = true
        eventGeneration += 1
        outputRouteSignature = Self.outputRouteSignature(for: session)
        let unrestored = pendingRestore.flatMap { $0.route == outputRouteSignature ? $0.volume : nil }
        pendingRestore = nil
        volumeWriter.cancel()
        restoreVolumesByRoute = [outputRouteSignature: unrestored ?? session.outputVolume]
        // Taken from where the operator left it, so for almost everyone the monitor opening
        // changes nothing they can hear, and no volume view is installed at all.
        presses.reanchor(volume: session.outputVolume)
        if MonitorRemoteShutterPolicy.needsWrite(from: session.outputVolume, to: presses.anchor) {
            setSystemVolume(presses.anchor)
        }
        // `outputVolume` KVO is Apple's documented observation path. It is the primary detector;
        // the notification below merely supplements it at the 0/1 rails. Both feed the same
        // debounce, so an OS that emits both still produces exactly one record toggle.
        let log = log
        // The audio session reports `outputVolume` on its own thread: no main-actor isolation, or
        // Swift 6 traps on entry where the SDK does not import the KVO handler as @Sendable.
        volumeObservation = session.observe(\.outputVolume, options: [.old, .new]) {
            @Sendable [weak self] session, change in
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
        routeRecoveryTask?.cancel()
        routeRecoveryTask = nil
        volumeObservation?.invalidate()
        volumeObservation = nil
        if let volumeObserver { NotificationCenter.default.removeObserver(volumeObserver) }
        volumeObserver = nil
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        // A slider still in hand restores synchronously while this monitor owns an active audio
        // session; otherwise the writer leases the view once more and restores just after.
        // Deactivation itself stays synchronous: a delayed one could end the clip player's session
        // after a rapid surface transition. Where the operator's level never moved, nothing is
        // written and no view is installed.
        let session = AVAudioSession.sharedInstance()
        let currentRouteSignature = Self.outputRouteSignature(for: session)
        if let restoreVolume = restoreVolumesByRoute[currentRouteSignature],
            MonitorRemoteShutterPolicy.needsWrite(from: session.outputVolume, to: restoreVolume)
        {
            if volumeWriter.writeNow(restoreVolume) {
                log.info("BT-SHUTTER restored volume=\(restoreVolume, privacy: .public)")
                volumeWriter.cancel()
            } else {
                pendingRestore = (currentRouteSignature, restoreVolume)
                log.info("BT-SHUTTER restoring volume=\(restoreVolume, privacy: .public) after stop")
                volumeWriter.write(restoreVolume)
            }
        } else {
            volumeWriter.cancel()
        }
        restoreVolumesByRoute.removeAll()
        outputRouteSignature = ""
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

    func adjudicateVolumeChange(_ newValue: Float, source: String) {
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
        let currentVolume = liveVolume()
        if now < suppressVolumeEventsUntil {
            log.info(
                "BT-SHUTTER ignored \(source, privacy: .public) event during audio-route change")
            if Self.volumeEventIsCurrent(newValue, currentVolume), abs(newValue - presses.anchor) > 0.001 {
                setSystemVolume(presses.anchor)
            }
            return
        }
        let decision = presses.observe(volume: newValue, currentVolume: currentVolume, at: now)
        log.info(
            "BT-SHUTTER event source=\(source, privacy: .public) volume=\(newValue, privacy: .public) current=\(currentVolume, privacy: .public) decision=\(decision?.rawValue ?? "stale", privacy: .public)"
        )
        guard let decision else { return }
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
        // and drop the leased MPVolumeView because its internal slider may be replaced for the new
        // route.
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
        volumeWriter.cancel()
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
            if MonitorRemoteShutterPolicy.needsWrite(from: routeVolume, to: self.presses.anchor) {
                self.setSystemVolume(self.presses.anchor)
            }
            self.routeRecoveryTask = nil
        }
    }

    static func volumeEventIsCurrent(_ captured: Float, _ current: Float) -> Bool {
        abs(captured - current) <= 0.001
    }

    private static func outputRouteSignature(for session: AVAudioSession) -> String {
        session.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.uid)" }
            .sorted()
            .joined(separator: "|")
    }

    private func setSystemVolume(_ value: Float) {
        presses.pinned(at: CFAbsoluteTimeGetCurrent())
        log.info("BT-SHUTTER setting volume=\(value, privacy: .public)")
        volumeWriter.write(value)
    }

    static func firstSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for subview in view.subviews {
            if let slider = firstSlider(in: subview) { return slider }
        }
        return nil
    }
}

/// The remote shutter's only way to set the system volume: the slider inside an `MPVolumeView`.
/// The view is leased (`MonitorRemoteShutterVolumeLease`): installed in the key window for a
/// write, removed a short hold after the last one, so an armed shutter at rest leaves nothing in
/// the window that keeps the app from idling. The window and view are injectable for tests.
@MainActor final class MonitorRemoteShutterVolumeWriter {
    /// Polls before the writer gives up on a slider that never appears: about 3 s at 0.15 s, then
    /// 20 s at 1 s. Giving up releases the view, so a broken OS release cannot pin the app awake.
    nonisolated static let acquisitionAttempts = 40

    var hostWindow: @MainActor () -> UIWindow? = {
        UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
    }
    /// The view must be genuinely in the visible hierarchy for its slider to work on device, so it
    /// sits at 1x1 pt in a corner at near-zero alpha rather than offscreen.
    var makeView: @MainActor () -> UIView = {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.alpha = 0.02
        return view
    }
    /// Called right after the slider moved, with the value written.
    var onWritten: (@MainActor (Float) -> Void)?

    private(set) var view: UIView?
    private var slider: UISlider?
    private var lease = MonitorRemoteShutterVolumeLease()
    private var task: Task<Void, Never>?
    private let log: Logger

    init(log: Logger) {
        self.log = log
    }

    /// Leases the view and writes `value` once its slider exists; the newest request wins.
    func write(_ value: Float) {
        lease.request(volume: value)
        install()
        task?.cancel()
        task = Task { @MainActor [weak self] in await self?.run() }
    }

    /// Writes at once when a slider is already in hand; false when it is not.
    @discardableResult
    func writeNow(_ value: Float) -> Bool {
        guard let slider else { return false }
        slider.setValue(value, animated: false)
        onWritten?(value)
        return true
    }

    /// Drops any pending write and removes the view now.
    func cancel() {
        task?.cancel()
        task = nil
        lease.end()
        remove()
    }

    private func run() async {
        // `MPVolumeView` builds its slider asynchronously after joining the hierarchy: searching
        // too early finds nothing, so poll until it appears.
        var attempt = 0
        while slider == nil {
            guard !Task.isCancelled else { return }
            if view == nil { install() }
            if let view, let found = MonitorRemoteShutter.firstSlider(in: view) {
                slider = found
                log.info(
                    "BT-SHUTTER slider acquired class=\(NSStringFromClass(type(of: found)), privacy: .public) attempt=\(attempt, privacy: .public)"
                )
                break
            }
            attempt += 1
            if attempt == 20 { log.error("BT-SHUTTER slider acquisition delayed; continuing to retry") }
            if attempt >= Self.acquisitionAttempts {
                log.error("BT-SHUTTER slider unavailable; releasing the volume view")
                cancel()
                return
            }
            try? await Task.sleep(for: attempt <= 20 ? .seconds(0.15) : .seconds(1))
        }
        // The slider ignores writes for a beat after appearing; a short defer makes them stick.
        try? await Task.sleep(for: .seconds(0.05))
        guard !Task.isCancelled, let slider, let value = lease.pendingVolume else { return }
        slider.setValue(value, animated: false)
        lease.wrote(at: CFAbsoluteTimeGetCurrent())
        onWritten?(value)
        try? await Task.sleep(for: .seconds(0.1))
        guard !Task.isCancelled else { return }
        log.info(
            "BT-SHUTTER volume readback requested=\(value, privacy: .public) actual=\(AVAudioSession.sharedInstance().outputVolume, privacy: .public)"
        )
        try? await Task.sleep(for: .seconds(MonitorRemoteShutterVolumeLease.hold))
        guard !Task.isCancelled, !lease.needsView(at: CFAbsoluteTimeGetCurrent()) else { return }
        task = nil
        remove()
    }

    private func install() {
        guard view == nil else { return }
        guard let window = hostWindow() else {
            log.error("BT-SHUTTER volume view has no key window")
            return
        }
        let view = makeView()
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        window.addSubview(view)
        self.view = view
        log.info("BT-SHUTTER volume view installed")
    }

    private func remove() {
        guard let view else { return }
        self.view = nil
        slider = nil
        view.removeFromSuperview()
        log.info("BT-SHUTTER volume view released")
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
