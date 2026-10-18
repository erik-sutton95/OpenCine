#if os(iOS)
import MonitorPresentation
import MonitorUI
import Observation
import OpenCineAppKit
import OpenCineCore
import SwiftUI

/// Owns mutually exclusive live panels and the delayed zoom dismissal for camera-vocabulary
/// hosts. The interface lock is the session's. Camera, gamepad and headphone input remain
/// adapters to the shared admission transition.
@MainActor @Observable
public final class MonitorOperatorInteraction {
    public var topMenu: LiveTopMenu?
    public private(set) var zoomVisible = false
    public private(set) var zoomMounted = false
    @ObservationIgnored private var zoomDismissal: Task<Void, Never>?
    @ObservationIgnored private var lifecycle = MonitorInteractionLifecycle()
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void

    public init(sleep: @escaping @MainActor (Duration) async throws -> Void = hostSleep(for:)) {
        self.sleep = sleep
    }

    public enum Panel: Equatable { case top, capture, drum, assist, motion, zoom }

    public func openZoom<Host: LiveChromeHost>(host: Host, motion: Binding<LiveGimbalPanel>) {
        guard !host.operatorSession.locked else { return }
        select(.zoom, host: host, motion: motion, reduceMotion: false)
        zoomDismissal?.cancel(); zoomDismissal = nil
        zoomMounted = true; zoomVisible = true
    }

    public func closeZoom<Host: LiveChromeHost>(host: Host, reduceMotion: Bool) {
        guard zoomVisible else { return }
        host.endZoomPinch()
        zoomVisible = false
        zoomDismissal?.cancel()
        if reduceMotion {
            zoomMounted = false; zoomDismissal = nil
            return
        }
        zoomDismissal = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await sleep(.milliseconds(190)) } catch { return }
            guard !Task.isCancelled, !zoomVisible else { return }
            zoomMounted = false; zoomDismissal = nil
        }
    }

    public func select<Host: LiveChromeHost>(_ panel: Panel, host: Host,
        motion: Binding<LiveGimbalPanel>, reduceMotion: Bool) {
        guard !host.operatorSession.locked else {
            dismiss(host: host, motion: motion, reduceMotion: reduceMotion)
            return
        }
        if panel != .top { topMenu = nil }
        if panel != .capture { host.captureSheet = nil }
        if panel != .drum { host.captureDrum = nil }
        if panel != .assist { host.assist.configureTool = nil }
        if panel != .motion && !(panel == .zoom && motion.wrappedValue == .editor) {
            motion.wrappedValue = .none
        }
        if panel != .zoom { closeZoom(host: host, reduceMotion: reduceMotion) }
    }

    func update<Host: LiveChromeHost>(_ context: MonitorInteractionContext, host: Host,
        motion: Binding<LiveGimbalPanel>, reduceMotion: Bool,
        input: (MonitorInputAdmission) -> Void) {
        apply(lifecycle.update(context), host: host, motion: motion,
            reduceMotion: reduceMotion, input: input)
        host.assist.liveCovered = context.covered && !context.editing
    }

    func disappear<Host: LiveChromeHost>(host: Host, motion: Binding<LiveGimbalPanel>,
        input: (MonitorInputAdmission) -> Void) {
        apply(lifecycle.close(), host: host, motion: motion, reduceMotion: true, input: input)
        zoomDismissal?.cancel(); zoomDismissal = nil
        zoomVisible = false; zoomMounted = false
        host.assist.liveCovered = false
    }

    private func apply<Host: LiveChromeHost>(_ transition: MonitorInteractionTransition,
        host: Host, motion: Binding<LiveGimbalPanel>, reduceMotion: Bool,
        input: (MonitorInputAdmission) -> Void) {
        if transition.dismissTransients { dismiss(host: host, motion: motion, reduceMotion: reduceMotion) }
        if transition.retireReadout { host.captureDrum = nil }
        if let admission = transition.inputAdmission { input(admission) }
    }

    private func dismiss<Host: LiveChromeHost>(host: Host, motion: Binding<LiveGimbalPanel>,
        reduceMotion: Bool) {
        topMenu = nil; host.captureSheet = nil; host.captureDrum = nil
        host.assist.configureTool = nil; motion.wrappedValue = .none
        closeZoom(host: host, reduceMotion: reduceMotion)
    }
}

extension View {
    /// One mounted owner applies common panel retirement before changing native input admission.
    public func monitorOperatorInteraction<Host: LiveChromeHost>(host: Host,
        interaction: MonitorOperatorInteraction, covered: Bool, motion: Binding<LiveGimbalPanel>,
        orientation: MonitorDeviceOrientation,
        onInputAdmission: @escaping (MonitorInputAdmission) -> Void) -> some View {
        modifier(MonitorOperatorInteractionModifier(host: host, interaction: interaction,
            covered: covered, motion: motion, orientation: orientation, input: onInputAdmission))
    }
}

private struct MonitorOperatorInteractionModifier<Host: LiveChromeHost>: ViewModifier {
    let host: Host
    let interaction: MonitorOperatorInteraction
    let covered: Bool
    let motion: Binding<LiveGimbalPanel>
    let orientation: MonitorDeviceOrientation
    let input: (MonitorInputAdmission) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var orientationRevision = 0

    private var context: MonitorInteractionContext {
        MonitorInteractionContext(locked: host.operatorSession.locked, covered: covered,
            editing: host.isEditingChrome, clean: host.assist.clean,
            toolbarMounted: host.chromeSectionMounts(.toolBar),
            camera: host.control.snapshot?.session, orientationRevision: orientationRevision)
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: context, initial: true) { _, next in
                interaction.update(next, host: host, motion: motion, reduceMotion: reduceMotion, input: input)
            }
            .onChange(of: orientation) { _, _ in orientationRevision += 1 }
            .onChange(of: interaction.topMenu) { _, menu in if menu != nil { select(.top) } }
            .onChange(of: host.captureSheet) { _, sheet in if sheet != nil { select(.capture) } }
            .onChange(of: host.captureDrum?.id) { _, drum in if drum != nil { select(.drum) } }
            .onChange(of: host.assist.configureTool) { _, tool in if tool != nil { select(.assist) } }
            .onChange(of: motion.wrappedValue) { _, panel in if panel != .none { select(.motion) } }
            .onChange(of: host.cameraStatus.isPhoto) { _, photo in
                host.captureSheet = CaptureReadoutAdmission.retained(host.captureSheet, isPhoto: photo)
                if CaptureReadoutAdmission.retainedDrum(host.captureDrum?.sheet, isPhoto: photo) == nil {
                    host.captureDrum = nil
                }
                if photo { interaction.topMenu = nil }
            }
            .onDisappear { interaction.disappear(host: host, motion: motion, input: input) }
    }

    private func select(_ panel: MonitorOperatorInteraction.Panel) {
        interaction.select(panel, host: host, motion: motion, reduceMotion: reduceMotion)
    }
}
#endif
